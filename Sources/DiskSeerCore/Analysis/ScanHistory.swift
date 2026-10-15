import Foundation

/// A compact summary of a scan, persisted to compare scans over time.
public struct ScanSnapshot: Codable, Sendable, Hashable {
    public let rootPath: String
    public let date: Date
    public let totalSize: Int64
    public let fileCount: Int
    /// Sizes of folders up to depth 3, keyed by path relative to the root.
    public let folders: [String: Int64]

    public init(root: FileNode, date: Date = Date(), maxDepth: Int = 3, minimumSize: Int64 = 50_000_000) {
        rootPath = root.path
        self.date = date
        totalSize = root.size
        fileCount = root.fileCount
        var folders: [String: Int64] = [:]
        func visit(_ node: FileNode, prefix: String, depth: Int) {
            for child in node.children where child.isContainer && child.size >= minimumSize {
                let rel = prefix.isEmpty ? child.name : prefix + "/" + child.name
                folders[rel] = child.size
                if depth < maxDepth { visit(child, prefix: rel, depth: depth + 1) }
            }
        }
        visit(root, prefix: "", depth: 1)
        self.folders = folders
    }
}

/// One folder that grew or shrank between two scans.
public struct SizeChange: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let before: Int64
    public let after: Int64
    public var delta: Int64 { after - before }
}

public enum ScanComparison {
    /// Biggest changes, excluding parents whose change is fully explained by a child.
    public static func changes(from old: ScanSnapshot, to new: ScanSnapshot, limit: Int = 15, threshold: Int64 = 100_000_000) -> [SizeChange] {
        var all: [SizeChange] = []
        for key in Set(old.folders.keys).union(new.folders.keys) {
            let before = old.folders[key] ?? 0
            let after = new.folders[key] ?? 0
            if abs(after - before) >= threshold { all.append(SizeChange(path: key, before: before, after: after)) }
        }
        // Prefer the most specific folder: drop a parent when a child explains >= 80% of its delta.
        let filtered = all.filter { parent in
            !all.contains { child in
                child.path.hasPrefix(parent.path + "/") && (child.delta.signum() == parent.delta.signum())
                    && Double(abs(child.delta)) >= 0.8 * Double(abs(parent.delta))
            }
        }
        return Array(filtered.sorted { abs($0.delta) > abs($1.delta) }.prefix(limit))
    }
}

/// Stores snapshots in ~/Library/Application Support/DiskSeer/History.
public struct ScanHistoryStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskSeer/History", isDirectory: true)
    }

    private func file(for rootPath: String) -> URL {
        let safe = rootPath.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe.isEmpty ? "root" : safe).json")
    }

    public func load(rootPath: String) -> [ScanSnapshot] {
        guard let data = try? Data(contentsOf: file(for: rootPath)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ScanSnapshot].self, from: data)) ?? []
    }

    /// Append a snapshot, keeping the most recent `keep` entries. Returns the previous snapshot.
    @discardableResult
    public func record(_ snapshot: ScanSnapshot, keep: Int = 20) -> ScanSnapshot? {
        var history = load(rootPath: snapshot.rootPath)
        let previous = history.last
        history.append(snapshot)
        if history.count > keep { history.removeFirst(history.count - keep) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(history).write(to: file(for: snapshot.rootPath), options: .atomic)
        } catch {
            // History is a convenience; failures are not fatal.
        }
        return previous
    }
}
