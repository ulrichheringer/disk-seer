import Foundation
import Testing
@testable import DiskSeerCore

@Suite("Disk scanner")
struct ScannerTests {
    @Test func scansNestedTreeAndAggregatesSizes() throws {
        let tmp = try TemporaryDirectory()
        try tmp.write("a/one.bin", bytes: 100_000)
        try tmp.write("a/b/two.bin", bytes: 50_000)
        try tmp.write("c.txt", bytes: 10)
        try tmp.mkdir("empty")

        let progress = ScanProgress()
        let root = try DiskScanner().scan(path: tmp.path, progress: progress)

        #expect(root.fileCount == 3)
        #expect(progress.files == 3)
        let a = try #require(root.child(named: "a"))
        let b = try #require(a.child(named: "b"))
        #expect(a.size == a.children.reduce(0) { $0 + $1.size })
        #expect(b.fileCount == 1)
        #expect(a.logicalSize == 150_000)
        // Allocated size is at least the logical size for non-compressed files.
        #expect(a.size >= 150_000)
        #expect(root.size == root.children.reduce(0) { $0 + $1.size })
        #expect(root.child(named: "empty")?.size == 0)
        #expect(root.child(named: "empty")?.isContainer == true)
    }

    @Test func countsHardLinksOnce() throws {
        let tmp = try TemporaryDirectory()
        let original = try tmp.write("original.bin", bytes: 200_000)
        try FileManager.default.linkItem(at: original, to: tmp.url.appendingPathComponent("link.bin"))
        let root = try DiskScanner().scan(path: tmp.path)
        let sizes = root.children.map(\.size).sorted()
        #expect(sizes.first == 0)
        #expect(root.children.filter(\.isHardLinkDuplicate).count == 1)
        #expect(root.size == sizes.last)
    }

    @Test func doesNotFollowSymlinks() throws {
        let tmp = try TemporaryDirectory()
        try tmp.write("real/big.bin", bytes: 300_000)
        try FileManager.default.createSymbolicLink(atPath: tmp.path + "/alias", withDestinationPath: tmp.path + "/real")
        let root = try DiskScanner().scan(path: tmp.path)
        let alias = try #require(root.child(named: "alias"))
        #expect(alias.kind == .symlink)
        #expect(alias.size < 10_000)
    }

    @Test func detectsPackagesAndExclusions() throws {
        let tmp = try TemporaryDirectory()
        try tmp.write("Thing.app/Contents/MacOS/Thing", bytes: 1000)
        try tmp.write("skip/me.bin", bytes: 1000)
        let options = ScanOptions(excludedPaths: [DiskScanner.normalize(tmp.path) + "/skip"])
        let root = try DiskScanner(options: options).scan(path: tmp.path)
        #expect(root.child(named: "Thing.app")?.kind == .package)
        #expect(root.child(named: "skip") == nil)
    }

    @Test func pathsAndLookupRoundTrip() throws {
        let tmp = try TemporaryDirectory()
        try tmp.write("x/y/z.txt", bytes: 5)
        let root = try DiskScanner().scan(path: tmp.path)
        let z = try #require(root.descendant(atRelativePath: "x/y/z.txt"))
        #expect(z.path == DiskScanner.normalize(tmp.path) + "/x/y/z.txt")
        #expect(root.node(atPath: z.path) === z)
        #expect(z.ancestry.count == 4)
        #expect(z.isDescendant(of: root))
    }

    @Test func rejectsFilesAndMissingPaths() throws {
        let tmp = try TemporaryDirectory()
        let f = try tmp.write("file.txt", bytes: 3)
        #expect(throws: ScanError.notADirectory(f.path)) { try DiskScanner().scan(path: f.path) }
        #expect(throws: (any Error).self) { try DiskScanner().scan(path: tmp.path + "/nope") }
    }

    @Test func serialAndParallelScansAgree() throws {
        let tmp = try TemporaryDirectory()
        for i in 0..<40 { try tmp.write("d\(i % 7)/e\(i % 3)/f\(i).bin", bytes: 1000 * (i + 1)) }
        let parallel = try DiskScanner().scan(path: tmp.path)
        let serial = try DiskScanner(options: ScanOptions(parallelDepth: 0)).scan(path: tmp.path)
        #expect(parallel.size == serial.size)
        #expect(parallel.fileCount == serial.fileCount)
        #expect(parallel.totalNodeCount == serial.totalNodeCount)
    }

    @Test func cancellationStopsEarly() throws {
        let tmp = try TemporaryDirectory()
        try tmp.write("a/b.bin", bytes: 10)
        let progress = ScanProgress()
        progress.cancel()
        let root = try DiskScanner().scan(path: tmp.path, progress: progress)
        #expect(root.fileCount == 0)
    }
}

@Suite("File tree")
struct FileNodeTests {
    @Test func removingChildPropagatesSizes() {
        let leaf = file("big", 500)
        let middle = dir("m", [leaf, file("small", 100)])
        let root = dir("/root", [middle, file("other", 50)])
        #expect(root.size == 650)
        #expect(leaf.detachFromParent())
        #expect(middle.size == 100)
        #expect(root.size == 150)
        #expect(root.fileCount == 2)
        #expect(leaf.parent == nil)
    }

    @Test func largestFilesUsesTopK() {
        let root = dir("/r", (1...50).map { file("f\($0)", Int64($0)) })
        let top = root.largestFiles(limit: 5)
        #expect(top.map(\.size) == [50, 49, 48, 47, 46])
        #expect(root.largestFiles(limit: 3, minimumSize: 49).count == 2)
    }

    @Test func newestModifiedBubblesUp() {
        let recent = file("new", 1, daysAgo: 1)
        let root = dir("/r", [dir("a", [file("old", 1, daysAgo: 900)], daysAgo: 900), dir("b", [recent], daysAgo: 900)], daysAgo: 900)
        #expect(abs(root.newestModified - recent.modified) < 1)
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test func bytes() {
        #expect(ByteFormat.string(0) == "0 B")
        #expect(ByteFormat.string(999) == "999 B")
        #expect(ByteFormat.string(1_500) == "1.50 KB")
        #expect(ByteFormat.string(23_900_000_000) == "23.9 GB")
        #expect(ByteFormat.string(512_000_000) == "512 MB")
        #expect(ByteFormat.string(-2_000) == "-2.00 KB")
        #expect(ByteFormat.percent(1, of: 4) == "25%")
        #expect(ByteFormat.percent(1, of: 100_000) == "<0.1%")
    }

    @Test func ages() {
        let now = Date()
        #expect(AgeFormat.relative(now.timeIntervalSince1970 - 30, now: now) == "just now")
        #expect(AgeFormat.relative(now.timeIntervalSince1970 - 3 * 86_400, now: now) == "3 days ago")
        #expect(AgeFormat.relative(now.timeIntervalSince1970 - 400 * 86_400, now: now) == "1 year ago")
        #expect(AgeFormat.short(now.timeIntervalSince1970 - 7200, now: now) == "2 h ago")
        #expect(AgeFormat.relative(0) == "unknown")
    }
}
