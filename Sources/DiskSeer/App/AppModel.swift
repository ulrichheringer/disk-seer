import AppKit
import DiskSeerCore
import Foundation
import Observation

/// Central state of the app. All mutation happens on the main actor; heavy work runs detached.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case failed(String)
    }

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case overview, explorer, insights, smartClean, largeFiles, duplicates, apps, virtualization
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .explorer: "Explorer"
            case .insights: "AI Insights"
            case .smartClean: "Smart Clean"
            case .largeFiles: "Large & Old Files"
            case .duplicates: "Duplicates"
            case .apps: "Applications"
            case .virtualization: "Docker & VMs"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.33percent"
            case .explorer: "square.grid.3x3.square"
            case .insights: "sparkles"
            case .smartClean: "wand.and.stars"
            case .largeFiles: "doc.badge.clock"
            case .duplicates: "doc.on.doc"
            case .apps: "app.badge.checkmark"
            case .virtualization: "shippingbox.circle"
            }
        }
    }

    enum ColorMode: String, CaseIterable, Identifiable {
        case category = "Kind", age = "Age", folder = "Folder"
        var id: String { rawValue }
    }

    enum DuplicateState: Equatable { case idle, running, done }

    enum Visualization: String, CaseIterable, Identifiable {
        case blocks = "Blocks", rings = "Rings"
        var id: String { rawValue }
        var symbol: String { self == .blocks ? "square.grid.2x2" : "circle.circle" }
    }

    struct TrashRequest: Identifiable {
        let id = UUID()
        let items: [(path: String, size: Int64)]
        let title: String
        var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    }

    struct CommandRequest: Identifiable {
        let id = UUID()
        let command: String
        let title: String
    }

    struct CommandResult: Identifiable {
        let id = UUID()
        let command: String
        let output: CommandRunner.Output
    }

    // MARK: State

    var phase: Phase = .idle
    var section: Section = .overview
    var root: FileNode?
    var scanPath = ""
    var volume: VolumeInfo?
    var volumes: [VolumeInfo] = VolumeInfo.mounted()
    var scanStats = ScanStats()
    var lastScanDuration: TimeInterval = 0
    var treeVersion = 0

    var zoomRoot: FileNode?
    var selection: FileNode?
    var colorMode: ColorMode = .category
    var visualization: Visualization = .blocks
    var explorerSearch = ""
    var showFreeSpace = true
    var treemapDepth = 6.0
    var showInspector = true

    let classifier = TreeClassifier()
    var findingSections: [FindingSection] = []
    var selectedFindings: Set<ObjectIdentifier> = []
    var categoryTotals: [(category: FileCategory, size: Int64)] = []

    var apps: [AppInfo] = []
    var leftovers: [AppLeftover] = []
    var appsLoading = false

    var duplicates: [DuplicateGroup] = []
    var duplicateState: DuplicateState = .idle
    var duplicateProgress: (hashed: Int, total: Int) = (0, 0)
    var duplicateMinimumSize: Int64 = 1_000_000
    var duplicateScope: DuplicateFinder.Scope = .personal
    private var duplicateTask: DuplicateFinder.Progress?

    var dockerUsage: DockerUsage?
    var virtualDisks: [VirtualDisk] = []
    var dockerLoading = false
    var localSnapshots: [String] = []

    var changes: [SizeChange] = []
    var previousScanDate: Date?
    var hasFullDiskAccess = AppModel.checkFullDiskAccess()

    var pendingTrash: TrashRequest?
    var pendingCommand: CommandRequest?
    var commandResult: CommandResult?
    var runningCommand: String?
    var toast: String?
    var trashSize: Int64 = 0

    private var currentProgress: ScanProgress?

    init() {
        // Keep free space figures live (other apps write to disk, Trash gets emptied...).
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                self.refreshVolumes()
            }
        }
    }

    func refreshVolumes() {
        volumes = VolumeInfo.mounted()
        if !scanPath.isEmpty { volume = VolumeInfo.forPath(scanPath) }
    }

    /// Free space of the startup disk for the menu bar.
    var startupFreeSpace: Int64 {
        (volumes.first(where: \.isRoot) ?? volumes.first)?.availableCapacity ?? 0
    }

    var startupDiskIsLow: Bool {
        guard let v = volumes.first(where: \.isRoot) ?? volumes.first else { return false }
        return v.usedFraction > 0.9
    }

    // MARK: Ignore list (persisted)

    var ignoredPaths: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredPaths") ?? []) {
        didSet { UserDefaults.standard.set(Array(ignoredPaths).sorted(), forKey: "ignoredPaths") }
    }
    var ignoredGroups: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredGroups") ?? []) {
        didSet { UserDefaults.standard.set(Array(ignoredGroups).sorted(), forKey: "ignoredGroups") }
    }

    /// Findings minus everything the user chose to ignore.
    var visibleFindingSections: [FindingSection] {
        findingSections.compactMap { section in
            guard !ignoredGroups.contains(section.group.id) else { return nil }
            let findings = section.findings.filter { !ignoredPaths.contains(ScanLocation.canonicalPath($0.path)) }
            return findings.isEmpty ? nil : FindingSection(group: section.group, findings: findings)
        }
    }

    func ignore(_ finding: CleanupFinding) {
        ignoredPaths.insert(ScanLocation.canonicalPath(finding.path))
        selectedFindings.remove(finding.id)
    }

    func ignore(group: FindingGroup) {
        ignoredGroups.insert(group.id)
        for f in findingSections.first(where: { $0.group.id == group.id })?.findings ?? [] { selectedFindings.remove(f.id) }
    }

    struct ScanStats: Equatable {
        var files = 0
        var directories = 0
        var bytes: Int64 = 0
        var restricted = 0
        var currentPath = ""
        var elapsed: TimeInterval = 0
    }

    // MARK: Derived

    var reclaimableSafe: Int64 {
        visibleFindingSections.flatMap(\.findings).filter { $0.safety == .safe }.reduce(0) { $0 + $1.size }
    }

    var reclaimableReview: Int64 {
        visibleFindingSections.flatMap(\.findings).filter { $0.safety >= .review }.reduce(0) { $0 + $1.size }
    }

    var selectedFindingSize: Int64 {
        visibleFindingSections.flatMap(\.findings).filter { selectedFindings.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var isEntireDisk: Bool { scanPath == ScanLocation.entireDisk || scanPath == "/" }

    var displayName: String {
        if isEntireDisk { return volume?.name ?? "Macintosh HD" }
        return scanPath.abbreviatingHome
    }

    /// Synthetic blocks representing free space and space outside the scanned folder.
    var extraBlocks: [FileNode] {
        guard showFreeSpace, let root, let volume, zoomRoot == nil || zoomRoot === root else { return [] }
        var blocks: [FileNode] = []
        let outside = volume.usedCapacity - root.size
        if outside > volume.totalCapacity / 200 {
            let name = isEntireDisk ? "System, snapshots & other volumes" : "Rest of the disk (outside this folder)"
            let n = FileNode(name: name, kind: .synthetic, size: outside, logicalSize: outside)
            blocks.append(n)
        }
        if volume.availableCapacity > 0 {
            blocks.append(FileNode(name: "Free space", kind: .synthetic, size: volume.availableCapacity, logicalSize: volume.availableCapacity))
        }
        return blocks
    }

    // MARK: Scanning

    func startScan(path rawPath: String) {
        cancelScan()
        let path = DiskScanner.normalize(rawPath)
        scanPath = path
        phase = .scanning
        scanStats = ScanStats()
        root = nil
        zoomRoot = nil
        selection = nil
        findingSections = []
        selectedFindings = []
        duplicates = []
        duplicateState = .idle
        changes = []
        volume = VolumeInfo.forPath(path)
        showFreeSpace = path == ScanLocation.entireDisk || path == "/"
        hasFullDiskAccess = AppModel.checkFullDiskAccess()

        let progress = ScanProgress()
        currentProgress = progress
        let classifier = self.classifier
        let started = Date()

        Task { [weak self] in
            while let self, self.phase == .scanning, !progress.isCancelled {
                self.scanStats = ScanStats(files: progress.files, directories: progress.directories, bytes: progress.bytes,
                                           restricted: progress.restricted, currentPath: progress.currentPath,
                                           elapsed: Date().timeIntervalSince(started))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        Task.detached(priority: .userInitiated) { [self] in
            do {
                let tree = try DiskScanner().scan(path: path, progress: progress)
                if progress.isCancelled { return }
                classifier.classify(root: tree)
                let sections = CleanupAnalyzer().analyze(root: tree)
                let totals = AppModel.computeCategoryTotals(tree)
                let snapshot = ScanSnapshot(root: tree)
                let store = ScanHistoryStore()
                let previous = store.load(rootPath: tree.path).last
                store.record(snapshot)
                let changes = previous.map { ScanComparison.changes(from: $0, to: snapshot) } ?? []
                let duration = Date().timeIntervalSince(started)
                await MainActor.run {
                    guard self.currentProgress === progress else { return }
                    self.root = tree
                    self.findingSections = sections
                    self.selectedFindings = Set(sections.flatMap(\.findings).filter { $0.safety == .safe }.map(\.id))
                    self.categoryTotals = totals
                    self.changes = changes
                    self.previousScanDate = previous?.date
                    self.lastScanDuration = duration
                    self.scanStats = ScanStats(files: progress.files, directories: progress.directories, bytes: progress.bytes,
                                               restricted: progress.restricted, currentPath: "", elapsed: duration)
                    self.treeVersion += 1
                    self.phase = .ready
                    self.refreshTrashSize()
                    self.loadApps()
                    self.loadVirtualization()
                }
            } catch {
                await MainActor.run {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelScan() {
        currentProgress?.cancel()
        if phase == .scanning { phase = root == nil ? .idle : .ready }
    }

    func rescan() {
        guard !scanPath.isEmpty else { return }
        startScan(path: scanPath)
    }

    nonisolated static func computeCategoryTotals(_ root: FileNode) -> [(category: FileCategory, size: Int64)] {
        var totals: [FileCategory: Int64] = [:]
        root.forEach { node in
            if node.kind == .file || node.kind == .symlink { totals[node.category, default: 0] += node.size }
        }
        return totals.map { ($0.key, $0.value) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    func loadApps() {
        guard !appsLoading else { return }
        appsLoading = true
        let tree = root
        Task.detached(priority: .utility) { [self] in
            var inventory = AppInventory.installedApps(sizesFrom: tree)
            let leftovers = AppInventory.analyzeLibrary(apps: &inventory, tree: tree)
            let apps = inventory
            let sections = tree.map { CleanupAnalyzer().analyze(root: $0, apps: apps, leftovers: leftovers) }
            await MainActor.run {
                self.apps = apps
                self.leftovers = leftovers
                self.appsLoading = false
                if let sections, self.root === tree {
                    let previouslySelected = self.selectedFindings
                    let previousIDs = Set(self.findingSections.flatMap(\.findings).map(\.id))
                    self.findingSections = sections
                    // Keep the user's choices; new safe findings start selected.
                    let newSafe = sections.flatMap(\.findings).filter { $0.safety == .safe && !previousIDs.contains($0.id) }.map(\.id)
                    self.selectedFindings = previouslySelected.union(newSafe)
                }
            }
        }
    }

    func loadVirtualization() {
        dockerLoading = true
        let tree = root
        Task.detached(priority: .utility) { [self] in
            let disks = VirtualizationInspector.discover(in: tree)
            let usage = DockerUsage.query()
            let snapshots = TimeMachineInsights.localSnapshots()
            await MainActor.run {
                self.virtualDisks = disks
                self.dockerUsage = usage
                self.localSnapshots = snapshots
                self.dockerLoading = false
            }
        }
    }

    // MARK: Duplicates

    func findDuplicates() {
        guard let root, duplicateState != .running else { return }
        duplicateState = .running
        duplicates = []
        let progress = DuplicateFinder.Progress()
        duplicateTask = progress
        let finder = DuplicateFinder(minimumSize: duplicateMinimumSize, scope: duplicateScope)
        Task { [weak self] in
            while let self, self.duplicateState == .running {
                self.duplicateProgress = (progress.hashed, progress.candidates)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        Task.detached(priority: .utility) { [self] in
            let groups = finder.findDuplicates(in: root, progress: progress)
            await MainActor.run {
                guard self.duplicateTask === progress else { return }
                self.duplicates = groups
                self.duplicateState = progress.isCancelled ? .idle : .done
            }
        }
    }

    func cancelDuplicates() {
        duplicateTask?.cancel()
        duplicateState = .idle
    }

    // MARK: Navigation

    func zoom(into node: FileNode) {
        guard node.isContainer, !node.isSynthetic else { return }
        zoomRoot = (node === root) ? nil : node
        selection = nil
        section = .explorer
    }

    func zoomOut() {
        guard let current = zoomRoot else { return }
        let parent = current.parent
        zoomRoot = (parent == nil || parent === root) ? nil : parent
        selection = current
    }

    /// Show `node` inside its folder in the Explorer.
    func reveal(_ node: FileNode) {
        section = .explorer
        if let parent = node.parent { zoomRoot = parent === root ? nil : parent }
        selection = node
    }

    // MARK: Cleanup

    func requestTrash(_ nodes: [FileNode], title: String? = nil) {
        let items = nodes.filter { !$0.isSynthetic }.map { (path: $0.path, size: $0.size) }
        guard !items.isEmpty else { return }
        pendingTrash = TrashRequest(items: items, title: title ?? (items.count == 1 ? (items[0].path as NSString).lastPathComponent : "\(items.count) items"))
    }

    func requestTrash(paths: [(path: String, size: Int64)], title: String) {
        guard !paths.isEmpty else { return }
        pendingTrash = TrashRequest(items: paths, title: title)
    }

    func requestTrashSelectedFindings() {
        let selected = visibleFindingSections.flatMap(\.findings).filter { selectedFindings.contains($0.id) }
        requestTrash(selected.map(\.node), title: "\(selected.count) selected items")
    }

    func verdict(for node: FileNode) -> SafetyPolicy.Verdict {
        SafetyPolicy().verdict(forPath: node.path)
    }

    func performTrash(_ request: TrashRequest) {
        pendingTrash = nil
        let items = request.items
        Task.detached(priority: .userInitiated) { [self] in
            let report = CleanupEngine().moveToTrash(items)
            await MainActor.run { self.apply(report) }
        }
    }

    private func apply(_ report: CleanupEngine.Report) {
        for result in report.succeeded {
            if let node = root?.node(atPath: result.path) {
                if selection.map({ $0 === node || $0.isDescendant(of: node) }) ?? false { selection = nil }
                if let zoom = zoomRoot, zoom === node || zoom.isDescendant(of: node) { zoomRoot = node.parent === root ? nil : node.parent }
                node.detachFromParent()
            }
            apps.removeAll { $0.path == result.path }
            leftovers.removeAll { $0.path == result.path }
        }
        // Drop findings whose node left the tree.
        findingSections = findingSections.compactMap { section in
            let remaining = section.findings.filter { finding in
                !report.succeeded.contains { finding.path == $0.path || finding.path.hasPrefix($0.path + "/") }
            }
            return remaining.isEmpty ? nil : FindingSection(group: section.group, findings: remaining)
        }
        duplicates = duplicates.compactMap { group in
            let files = group.files.filter { file in !report.succeeded.contains { $0.path == file.path } }
            return files.count > 1 ? DuplicateGroup(id: group.id, files: files, fileSize: group.fileSize) : nil
        }
        if let root { categoryTotals = AppModel.computeCategoryTotals(root) }
        treeVersion += 1
        refreshTrashSize()
        var message = "Moved \(report.succeeded.count) item\(report.succeeded.count == 1 ? "" : "s") (\(ByteFormat.string(report.freedBytes))) to the Trash."
        if !report.failed.isEmpty {
            message += " \(report.failed.count) could not be moved: \(report.failed.first?.error ?? "")"
        }
        showToast(message)
    }

    func refreshTrashSize() {
        let path = NSHomeDirectory() + "/.Trash"
        Task.detached(priority: .utility) { [self] in
            let size = (try? DiskScanner(options: ScanOptions(parallelDepth: 0)).scan(path: path).size) ?? 0
            await MainActor.run { self.trashSize = size }
        }
    }

    func emptyTrash() {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            showToast("Could not empty the Trash: \(error[NSAppleScript.errorMessage] ?? "permission denied")")
        } else {
            showToast("Trash emptied.")
            volume = VolumeInfo.forPath(scanPath)
            if let trash = root?.node(atPath: NSHomeDirectory() + "/.Trash") {
                for child in trash.children { trash.removeChild(child) }
                treeVersion += 1
            }
            findingSections.removeAll { $0.group.id == "sys.trash" }
        }
        refreshTrashSize()
    }

    func run(_ request: CommandRequest) {
        pendingCommand = nil
        runningCommand = request.command
        Task.detached(priority: .userInitiated) { [self] in
            let output = CommandRunner.run(request.command)
            await MainActor.run {
                self.runningCommand = nil
                self.commandResult = CommandResult(command: request.command, output: output)
                self.volume = VolumeInfo.forPath(self.scanPath)
                if request.command.contains("docker") || request.command.contains("podman") { self.loadVirtualization() }
            }
        }
    }

    func showToast(_ message: String) {
        toast = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.toast == message { self?.toast = nil }
        }
    }

    // MARK: Permissions

    static func checkFullDiskAccess() -> Bool {
        let probes = [NSHomeDirectory() + "/Library/Safari", NSHomeDirectory() + "/Library/Mail",
                      "/Library/Application Support/com.apple.TCC"]
        for probe in probes where FileManager.default.fileExists(atPath: probe) {
            if (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil { return true }
            return false
        }
        return true
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
