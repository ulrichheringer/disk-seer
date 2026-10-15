import Darwin
import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    /// Descend into other mounted volumes found below the scan root.
    public var crossVolumes: Bool = false
    /// Absolute paths that should not be scanned.
    public var excludedPaths: Set<String> = []
    /// Directories up to this depth have their subdirectories scanned in parallel.
    public var parallelDepth: Int = 4

    public static let defaultPackageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "photoslibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band",
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "pvm", "utm", "vmwarevm",
        "sparsebundle", "rtfd", "pages", "numbers", "key", "lproj", "dSYM", "mlmodelc",
        "photoslibrarybackup", "aplibrary", "lrlibrary", "lrdata", "saver", "prefPane",
        "qlgenerator", "mdimporter", "wdgt", "docset", "noindex",
    ].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

    public var packageExtensions: Set<String> = ScanOptions.defaultPackageExtensions

    public init(crossVolumes: Bool = false, excludedPaths: Set<String> = [], parallelDepth: Int = 4) {
        self.crossVolumes = crossVolumes
        self.excludedPaths = excludedPaths
        self.parallelDepth = parallelDepth
    }
}

/// Thread-safe live progress of a running scan.
public final class ScanProgress: Sendable {
    private let filesCounter = Atomic<Int>(0)
    private let directoriesCounter = Atomic<Int>(0)
    private let bytesCounter = Atomic<Int64>(0)
    private let restrictedCounter = Atomic<Int>(0)
    private let cancelledFlag = Atomic<Bool>(false)
    private let currentPathStorage = Mutex<String>("")

    public init() {}

    public var files: Int { filesCounter.load(ordering: .relaxed) }
    public var directories: Int { directoriesCounter.load(ordering: .relaxed) }
    public var bytes: Int64 { bytesCounter.load(ordering: .relaxed) }
    public var restricted: Int { restrictedCounter.load(ordering: .relaxed) }
    public var isCancelled: Bool { cancelledFlag.load(ordering: .relaxed) }
    public var currentPath: String { currentPathStorage.withLock { $0 } }

    public func cancel() { cancelledFlag.store(true, ordering: .relaxed) }

    func addFiles(_ count: Int, bytes: Int64) {
        filesCounter.add(count, ordering: .relaxed)
        bytesCounter.add(bytes, ordering: .relaxed)
    }

    func addDirectory() -> Int {
        directoriesCounter.add(1, ordering: .relaxed).newValue
    }

    func addRestricted() { restrictedCounter.add(1, ordering: .relaxed) }
    func setCurrentPath(_ path: String) { currentPathStorage.withLock { $0 = path } }
}

/// Fast, parallel file-system scanner built directly on POSIX calls.
///
/// It measures *allocated* size (what actually uses disk space), counts
/// hard-linked files once, never follows symlinks and by default does not
/// cross into other volumes.
public struct DiskScanner: Sendable {
    public let options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    private struct HardLinkKey: Hashable { let device: Int32; let inode: UInt64 }

    private final class Context: @unchecked Sendable {
        let rootDevice: Int32
        let options: ScanOptions
        let progress: ScanProgress
        let hardLinks = Mutex<Set<HardLinkKey>>([])
        let excluded: Set<String>
        let group = DispatchGroup()
        let inFlight = Atomic<Int>(0)
        let maxInFlight: Int
        let useBulk = Atomic<Bool>(true)

        init(rootDevice: Int32, options: ScanOptions, progress: ScanProgress) {
            self.rootDevice = rootDevice
            self.options = options
            self.progress = progress
            self.excluded = options.excludedPaths
            self.maxInFlight = options.parallelDepth > 0 ? max(ProcessInfo.processInfo.activeProcessorCount * 2, 4) : 0
        }

        /// Returns true the first time a given hard-linked inode is seen.
        func registerHardLink(device: Int32, inode: UInt64) -> Bool {
            hardLinks.withLock { $0.insert(HardLinkKey(device: device, inode: inode)).inserted }
        }

        func tryAcquireWorker() -> Bool {
            guard maxInFlight > 0 else { return false }
            var current = inFlight.load(ordering: .relaxed)
            while current < maxInFlight {
                let (exchanged, original) = inFlight.compareExchange(expected: current, desired: current + 1, ordering: .acquiringAndReleasing)
                if exchanged { return true }
                current = original
            }
            return false
        }

        func releaseWorker() { inFlight.subtract(1, ordering: .relaxed) }
    }

    /// Scan the directory at `path` and return the populated tree.
    public func scan(path rawPath: String, progress: ScanProgress = ScanProgress()) throws -> FileNode {
        let path = DiskScanner.normalize(rawPath)
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw ScanError.cannotAccess(path, String(cString: strerror(errno)))
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ScanError.notADirectory(path) }

        DiskScanner.raiseFileDescriptorLimit()

        let root = FileNode(
            name: path,
            kind: .directory,
            modified: TimeInterval(st.st_mtimespec.tv_sec),
            accessed: TimeInterval(st.st_atimespec.tv_sec)
        )
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw ScanError.cannotAccess(path, String(cString: strerror(errno)))
        }
        let context = Context(rootDevice: st.st_dev, options: options, progress: progress)
        scanDirectory(fd: fd, node: root, context: context)
        context.group.wait()
        DiskScanner.aggregate(root)
        return root
    }

    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        if p.isEmpty { p = "/" }
        return p
    }

    /// Post-order pass computing folder sizes from their children.
    static func aggregate(_ root: FileNode) {
        var stack: [(FileNode, Bool)] = [(root, false)]
        while let (node, expanded) = stack.popLast() {
            if expanded {
                node.recomputeAggregates()
                continue
            }
            guard node.isContainer else { continue }
            stack.append((node, true))
            for child in node.children where child.isContainer { stack.append((child, false)) }
        }
    }

    /// Reads one directory (fd is consumed) and schedules its subdirectories.
    private func scanDirectory(fd: Int32, node: FileNode, context: Context) {
        let progress = context.progress
        if progress.addDirectory() % 512 == 0 {
            progress.setCurrentPath(node.path)
        }
        var children: [FileNode] = []
        var subdirectories: [FileNode] = []
        var fileCount = 0
        var fileBytes: Int64 = 0
        let checkExclusions = !context.excluded.isEmpty
        let basePath = checkExclusions ? node.path : ""

        let sink: (EntryInfo) -> Void = { entry in
            switch entry.type {
            case .directory:
                if !context.options.crossVolumes && entry.device != context.rootDevice { return }
                if checkExclusions {
                    let childPath = basePath == "/" ? "/" + entry.name : basePath + "/" + entry.name
                    if context.excluded.contains(childPath) { return }
                }
                let ext = DiskScanner.extensionOf(entry.name)
                let isPackage = !ext.isEmpty && context.options.packageExtensions.contains(ext)
                let child = FileNode(name: entry.name, kind: isPackage ? .package : .directory,
                                     modified: entry.modified, accessed: entry.accessed)
                children.append(child)
                subdirectories.append(child)
            case .file:
                let child = FileNode(name: entry.name, kind: .file, size: entry.allocated, logicalSize: entry.logical,
                                     modified: entry.modified, accessed: entry.accessed)
                var allocated = entry.allocated
                if entry.linkCount > 1 && !context.registerHardLink(device: entry.device, inode: entry.inode) {
                    allocated = 0
                    child.size = 0
                    child.markHardLinkDuplicate()
                }
                children.append(child)
                fileCount += 1
                fileBytes += allocated
            case .symlink:
                children.append(FileNode(name: entry.name, kind: .symlink, size: entry.allocated, logicalSize: entry.logical,
                                         modified: entry.modified, accessed: entry.accessed))
            case .other:
                return
            }
        }

        var readOK = false
        if context.useBulk.load(ordering: .relaxed) {
            readOK = DiskScanner.readEntriesBulk(fd: fd, progress: progress, sink)
            if !readOK && children.isEmpty {
                // File system without getattrlistbulk support: fall back for the rest of the scan.
                lseek(fd, 0, SEEK_SET)
            }
        }
        if !readOK && children.isEmpty {
            readOK = DiskScanner.readEntriesPOSIX(fd: fd, progress: progress, sink)
        }
        if !readOK && children.isEmpty {
            node.isRestricted = true
            progress.addRestricted()
        }
        if fileCount > 0 { progress.addFiles(fileCount, bytes: fileBytes) }
        node.setChildren(children)

        for child in subdirectories {
            if progress.isCancelled { break }
            let childFD = openat(fd, child.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if childFD < 0 {
                child.isRestricted = true
                progress.addRestricted()
                continue
            }
            if context.tryAcquireWorker() {
                context.group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    scanDirectory(fd: childFD, node: child, context: context)
                    context.releaseWorker()
                    context.group.leave()
                }
            } else {
                scanDirectory(fd: childFD, node: child, context: context)
            }
        }
        close(fd)
    }

    struct EntryInfo {
        enum EntryType { case file, directory, symlink, other }
        var name: String
        var type: EntryType
        var device: Int32
        var inode: UInt64
        var linkCount: UInt32
        var allocated: Int64
        var logical: Int64
        var modified: TimeInterval
        var accessed: TimeInterval
    }

    private static let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!

    /// Classic readdir + fstatat enumeration.
    private static func readEntriesPOSIX(fd: Int32, progress: ScanProgress, _ sink: (EntryInfo) -> Void) -> Bool {
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else { return false }
        defer { closedir(dir) }
        let dfd = dirfd(dir)
        while let entry = readdir(dir) {
            if progress.isCancelled { break }
            let namePointer = UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
            if namePointer[0] == 0x2E && (namePointer[1] == 0 || (namePointer[1] == 0x2E && namePointer[2] == 0)) { continue }
            var st = stat()
            guard fstatat(dfd, namePointer, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let type: EntryInfo.EntryType
            switch st.st_mode & S_IFMT {
            case S_IFDIR: type = .directory
            case S_IFREG: type = .file
            case S_IFLNK: type = .symlink
            default: type = .other
            }
            sink(EntryInfo(name: String(cString: namePointer), type: type, device: st.st_dev, inode: st.st_ino,
                           linkCount: UInt32(st.st_nlink), allocated: Int64(st.st_blocks) * 512, logical: Int64(st.st_size),
                           modified: TimeInterval(st.st_mtimespec.tv_sec), accessed: TimeInterval(st.st_atimespec.tv_sec)))
        }
        return true
    }

    /// Batched enumeration with getattrlistbulk(2): one syscall returns metadata for many entries.
    private static func readEntriesBulk(fd: Int32, progress: ScanProgress, _ sink: (EntryInfo) -> Void) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_ACCTIME) | attrgroup_t(ATTR_CMN_FILEID)
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            if progress.isCancelled { return true }
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, 0)
            if count < 0 { return false }
            if count == 0 { return true }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = entry.loadUnaligned(as: UInt32.self)
                var field = entry.advanced(by: 4)
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field = field.advanced(by: MemoryLayout<attribute_set_t>.size)
                defer { entry = entry.advanced(by: Int(length)) }

                var error: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    error = field.loadUnaligned(as: UInt32.self)
                    field = field.advanced(by: 4)
                }
                var name = ""
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    let namePtr = field.advanced(by: Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    name = String(cString: namePtr)
                    field = field.advanced(by: MemoryLayout<attrreference_t>.size)
                }
                if error != 0 || name.isEmpty { continue }
                var device: Int32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                    device = field.loadUnaligned(as: Int32.self)
                    field = field.advanced(by: 4)
                }
                var objType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objType = field.loadUnaligned(as: UInt32.self)
                    field = field.advanced(by: 4)
                }
                var modified: TimeInterval = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    modified = TimeInterval(field.loadUnaligned(as: timespec.self).tv_sec)
                    field = field.advanced(by: MemoryLayout<timespec>.size)
                }
                var accessed: TimeInterval = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_ACCTIME) != 0 {
                    accessed = TimeInterval(field.loadUnaligned(as: timespec.self).tv_sec)
                    field = field.advanced(by: MemoryLayout<timespec>.size)
                }
                var inode: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    inode = field.loadUnaligned(as: UInt64.self)
                    field = field.advanced(by: 8)
                }
                var linkCount: UInt32 = 1
                var logical: Int64 = 0
                var allocated: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                    linkCount = field.loadUnaligned(as: UInt32.self)
                    field = field.advanced(by: 4)
                }
                if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 {
                    logical = field.loadUnaligned(as: Int64.self)
                    field = field.advanced(by: 8)
                }
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    allocated = field.loadUnaligned(as: Int64.self)
                    field = field.advanced(by: 8)
                }
                let type: EntryInfo.EntryType
                switch objType {
                case UInt32(VREG.rawValue): type = .file
                case UInt32(VDIR.rawValue): type = .directory
                case UInt32(VLNK.rawValue): type = .symlink
                default: type = .other
                }
                sink(EntryInfo(name: name, type: type, device: device, inode: inode, linkCount: linkCount,
                               allocated: allocated, logical: logical, modified: modified, accessed: accessed))
            }
        }
    }

    static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    private static func raiseFileDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let desired: rlim_t = 10_240
        if limit.rlim_cur < desired {
            limit.rlim_cur = min(desired, limit.rlim_max)
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }
}

public enum ScanError: LocalizedError, Equatable {
    case cannotAccess(String, String)
    case notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .cannotAccess(path, reason): "Cannot access \(path): \(reason)"
        case let .notADirectory(path): "\(path) is not a folder"
        }
    }
}
