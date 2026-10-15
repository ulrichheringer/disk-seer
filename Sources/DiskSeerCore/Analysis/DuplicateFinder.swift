import CryptoKit
import Darwin
import Foundation
import Synchronization

/// A set of files with identical content.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let files: [FileNode]
    public let fileSize: Int64
    /// Space that would be freed by keeping only one copy.
    public init(id: String, files: [FileNode], fileSize: Int64) {
        self.id = id
        self.files = files
        self.fileSize = fileSize
    }

    public var wastedBytes: Int64 { fileSize * Int64(max(files.count - 1, 0)) }

    public static func == (lhs: DuplicateGroup, rhs: DuplicateGroup) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The copy we suggest keeping: the oldest one outside Downloads/caches.
    public var suggestedOriginal: FileNode? {
        files.min { a, b in
            let ra = DuplicateGroup.rank(a), rb = DuplicateGroup.rank(b)
            if ra != rb { return ra < rb }
            return a.modified < b.modified
        }
    }

    static func rank(_ node: FileNode) -> Int {
        let path = node.path
        if path.contains("/Downloads/") { return 3 }
        if path.contains("/Caches/") || path.contains("/.Trash/") { return 4 }
        if path.contains("/Desktop/") { return 2 }
        return 1
    }
}

/// Finds duplicate files: size buckets → partial hash (head + tail) → full SHA-256.
public struct DuplicateFinder: Sendable {
    public enum Scope: String, Sendable, CaseIterable {
        /// Documents, media and downloads only: never app data, tool installs, caches or project dependencies.
        case personal
        /// Every regular file outside bundles.
        case everything
    }

    public var minimumSize: Int64
    public var skipPackages: Bool
    public var scope: Scope

    public init(minimumSize: Int64 = 1_000_000, skipPackages: Bool = true, scope: Scope = .personal) {
        self.minimumSize = minimumSize
        self.skipPackages = skipPackages
        self.scope = scope
    }

    private static let managedCategories: Set<FileCategory> = [
        .applications, .system, .developer, .buildArtifacts, .dependencies, .packageCaches, .caches, .logs,
        .virtualMachines, .code, .aiModels,
    ]

    /// Whether a folder may contain user-managed files for the personal scope.
    static func isPersonalFolder(_ node: FileNode) -> Bool {
        if managedCategories.contains(node.category) && node.parent != nil { return false }
        let name = node.name
        if node.parent != nil && name.hasPrefix(".") { return false }
        if ["node_modules", "vendor", "site-packages", "Library", "DerivedData", "build", "dist", "target", "Pods"].contains(name) && node.parent != nil {
            // ~/Library and project dependency folders are app/tool managed.
            return false
        }
        return true
    }

    public final class Progress: Sendable {
        private let hashedFiles = Atomic<Int>(0)
        private let totalCandidates = Atomic<Int>(0)
        private let cancelledFlag = Atomic<Bool>(false)
        public init() {}
        public var hashed: Int { hashedFiles.load(ordering: .relaxed) }
        public var candidates: Int { totalCandidates.load(ordering: .relaxed) }
        public var isCancelled: Bool { cancelledFlag.load(ordering: .relaxed) }
        public func cancel() { cancelledFlag.store(true, ordering: .relaxed) }
        func setCandidates(_ n: Int) { totalCandidates.store(n, ordering: .relaxed) }
        func didHash() { hashedFiles.add(1, ordering: .relaxed) }
    }

    public func findDuplicates(in root: FileNode, progress: Progress = Progress()) -> [DuplicateGroup] {
        // 1. Bucket by logical size.
        var bySize: [Int64: [FileNode]] = [:]
        let personal = scope == .personal
        root.walk { node in
            if node.kind == .package && skipPackages { return false }
            if personal && node.isContainer && !DuplicateFinder.isPersonalFolder(node) { return false }
            if personal && node.kind == .file && DuplicateFinder.managedCategories.contains(node.category) { return false }
            if node.kind == .file && node.logicalSize >= minimumSize && !node.isHardLinkDuplicate && node.size > 0 {
                bySize[node.logicalSize, default: []].append(node)
            }
            return node.isContainer
        }
        let buckets = bySize.filter { $0.value.count > 1 }
        progress.setCandidates(buckets.values.reduce(0) { $0 + $1.count })

        // 2. Partial and full hashes, bucket by bucket in parallel.
        let bucketList = Array(buckets.values)
        let output = Mutex<[DuplicateGroup]>([])
        DispatchQueue.concurrentPerform(iterations: bucketList.count) { index in
            if progress.isCancelled { return }
            let files = bucketList[index]
            var byPartial: [String: [FileNode]] = [:]
            for file in files {
                if progress.isCancelled { return }
                if let h = DuplicateFinder.partialHash(path: file.path, size: file.logicalSize) {
                    byPartial[h, default: []].append(file)
                }
                progress.didHash()
            }
            for (_, candidates) in byPartial where candidates.count > 1 {
                var byFull: [String: [FileNode]] = [:]
                // Small files: the partial hash already covered the entire content.
                if candidates[0].logicalSize <= 2 * DuplicateFinder.chunk {
                    byFull["p"] = candidates
                } else {
                    for file in candidates {
                        if progress.isCancelled { return }
                        if let h = DuplicateFinder.fullHash(path: file.path) { byFull[h, default: []].append(file) }
                    }
                }
                for (hash, same) in byFull where same.count > 1 {
                    let group = DuplicateGroup(id: "\(same[0].logicalSize)-\(hash)-\(same[0].path)", files: same.sorted { $0.path < $1.path },
                                               fileSize: same[0].size)
                    output.withLock { $0.append(group) }
                }
            }
        }
        return output.withLock { $0 }.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    static let chunk: Int64 = 64 * 1024

    static func partialHash(path: String, size: Int64) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: Int(chunk))
        func readChunk(at offset: Int64) -> Bool {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(chunk), off_t(offset)) }
            guard n >= 0 else { return false }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            return true
        }
        guard readChunk(at: 0) else { return nil }
        if size > chunk {
            guard readChunk(at: max(chunk, size - chunk)) else { return nil }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        let size = 1 << 20
        var buffer = [UInt8](repeating: 0, count: size)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, size) }
            if n < 0 { return nil }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
