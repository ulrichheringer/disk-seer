import Foundation

/// Moves items to the Trash after checking them against the `SafetyPolicy`.
public struct CleanupEngine: Sendable {
    public struct ItemResult: Sendable, Identifiable {
        public var id: String { path }
        public let path: String
        public let size: Int64
        public let trashedURL: URL?
        public let error: String?
        public var succeeded: Bool { error == nil }
    }

    public struct Report: Sendable {
        public let results: [ItemResult]
        public let dryRun: Bool
        public var freedBytes: Int64 { results.filter(\.succeeded).reduce(0) { $0 + $1.size } }
        public var succeeded: [ItemResult] { results.filter(\.succeeded) }
        public var failed: [ItemResult] { results.filter { !$0.succeeded } }
    }

    public let policy: SafetyPolicy
    /// The function that actually moves a URL to the Trash (injectable for tests).
    public var trash: @Sendable (URL) throws -> URL?

    public init(policy: SafetyPolicy = SafetyPolicy(),
                trash: @escaping @Sendable (URL) throws -> URL? = CleanupEngine.moveToTrash) {
        self.policy = policy
        self.trash = trash
    }

    public static let moveToTrash: @Sendable (URL) throws -> URL? = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Remove the given items (path + size). Overlapping items (one inside another) are collapsed.
    public func moveToTrash(_ items: [(path: String, size: Int64)], dryRun: Bool = false) -> Report {
        let collapsed = CleanupEngine.collapseNested(items)
        var results: [ItemResult] = []
        for item in collapsed {
            let verdict = policy.verdict(forPath: item.path)
            guard verdict.isAllowed else {
                results.append(ItemResult(path: item.path, size: item.size, trashedURL: nil, error: verdict.reason))
                continue
            }
            guard FileManager.default.fileExists(atPath: item.path) || isDanglingSymlink(item.path) else {
                results.append(ItemResult(path: item.path, size: item.size, trashedURL: nil, error: "Item no longer exists."))
                continue
            }
            if dryRun {
                results.append(ItemResult(path: item.path, size: item.size, trashedURL: nil, error: nil))
                continue
            }
            do {
                let url = try trash(URL(fileURLWithPath: item.path))
                results.append(ItemResult(path: item.path, size: item.size, trashedURL: url, error: nil))
            } catch {
                results.append(ItemResult(path: item.path, size: item.size, trashedURL: nil, error: error.localizedDescription))
            }
        }
        return Report(results: results, dryRun: dryRun)
    }

    private func isDanglingSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// Drop items that are inside another selected item.
    public static func collapseNested(_ items: [(path: String, size: Int64)]) -> [(path: String, size: Int64)] {
        let sorted = items.sorted { $0.path.count < $1.path.count }
        var kept: [(path: String, size: Int64)] = []
        var keptPaths = Set<String>()
        for item in sorted {
            if keptPaths.contains(item.path) { continue }
            var parent = (item.path as NSString).deletingLastPathComponent
            var nested = false
            while parent.count > 1 {
                if keptPaths.contains(parent) { nested = true; break }
                parent = (parent as NSString).deletingLastPathComponent
            }
            if !nested {
                kept.append(item)
                keptPaths.insert(item.path)
            }
        }
        return kept
    }
}

/// Runs a shell command (e.g. `brew cleanup`) with a login-like PATH.
public enum CommandRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { status == 0 }
    }

    public static let searchPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
        + NSHomeDirectory() + "/.orbstack/bin:" + NSHomeDirectory() + "/.cargo/bin:" + NSHomeDirectory() + "/go/bin:"
        + "/Applications/Docker.app/Contents/Resources/bin"

    /// Locate an executable on the extended search path.
    public static func which(_ tool: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run `command` through /bin/zsh with a timeout.
    public static func run(_ command: String, timeout: TimeInterval = 600) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let collector = PipeCollector(out: out, err: err)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let (o, e) = collector.finish()
        return Output(status: process.terminationStatus, stdout: o, stderr: e)
    }

    private final class PipeCollector: @unchecked Sendable {
        private var outData = Data(), errData = Data()
        private let lock = NSLock()
        private let group = DispatchGroup()

        init(out: Pipe, err: Pipe) {
            read(out.fileHandleForReading) { [self] d in lock.withLock { outData.append(d) } }
            read(err.fileHandleForReading) { [self] d in lock.withLock { errData.append(d) } }
        }

        private func read(_ handle: FileHandle, _ append: @escaping @Sendable (Data) -> Void) {
            group.enter()
            DispatchQueue.global().async { [group] in
                let data = handle.readDataToEndOfFile()
                append(data)
                group.leave()
            }
        }

        func finish() -> (String, String) {
            _ = group.wait(timeout: .now() + 5)
            return lock.withLock { (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self)) }
        }
    }
}
