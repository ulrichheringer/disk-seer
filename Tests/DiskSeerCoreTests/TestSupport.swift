import Foundation
@testable import DiskSeerCore

/// Builds synthetic trees quickly: `dir("a", [file("b", 10)])`.
func file(_ name: String, _ size: Int64 = 1000, daysAgo: Double = 1) -> FileNode {
    let t = Date().timeIntervalSince1970 - daysAgo * 86_400
    return FileNode(name: name, kind: .file, size: size, logicalSize: size, modified: t, accessed: t)
}

func dir(_ name: String, _ children: [FileNode] = [], daysAgo: Double = 1, kind: FileNode.Kind = .directory) -> FileNode {
    let t = Date().timeIntervalSince1970 - daysAgo * 86_400
    return FileNode(name: name, kind: kind, modified: t, accessed: t, children: children)
}

/// A temporary directory removed when the value is deinitialized.
final class TemporaryDirectory {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSeerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, bytes: Int, fill: UInt8 = 0x41) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: target)
        return target
    }

    func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(relative), withIntermediateDirectories: true)
    }
}
