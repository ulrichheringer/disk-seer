import CoreGraphics
import Foundation
import Testing
@testable import DiskSeerCore

private let home = "/Users/tester"

@Suite("Smart Clean analyzer")
struct CleanupAnalyzerTests {
    let engine = RuleEngine(home: home)

    private func analyze(_ root: FileNode) -> [FindingSection] {
        TreeClassifier(engine: engine).classify(root: root)
        return CleanupAnalyzer(engine: engine).analyze(root: root)
    }

    @Test func staleProjectDependenciesAreSafeActiveOnesNeedReview() throws {
        let staleModules = dir("node_modules", [file("lib.js", 50_000_000, daysAgo: 200)], daysAgo: 200)
        let stale = dir("old-app", [file("package.json", 1000, daysAgo: 200), staleModules], daysAgo: 200)
        let activeModules = dir("node_modules", [file("lib.js", 40_000_000, daysAgo: 1)])
        let active = dir("new-app", [file("package.json", 1000, daysAgo: 0.1), activeModules])
        let root = dir(home, [dir("dev", [stale, active])])
        let section = try #require(analyze(root).first { $0.group.id == "proj.nodemodules" })
        #expect(section.findings.count == 2)
        #expect(section.findings.first { $0.node === staleModules }?.safety == .safe)
        #expect(section.findings.first { $0.node === activeModules }?.safety == .review)
    }

    @Test func toolManagedFoldersAreNeverReportedAsProjects() {
        // dist/ inside an installed VS Code extension must not be offered for deletion.
        let dist = dir("dist", [file("extension.js", 30_000_000)])
        let ext = dir("publisher.ext-1.0.0", [file("package.json", 100), dist, dir("node_modules", [file("x.js", 20_000_000)])])
        let root = dir(home, [dir(".vscode", [dir("extensions", [ext])])])
        let sections = analyze(root)
        #expect(!sections.contains { $0.group.id == "proj.jsdist" })
        #expect(!sections.contains { $0.group.id == "proj.nodemodules" })
        #expect(CleanupAnalyzer.isUserProjectArea("~/dev/app/node_modules"))
        #expect(!CleanupAnalyzer.isUserProjectArea("~/.nvm/versions/node/v20/lib/node_modules"))
        #expect(!CleanupAnalyzer.isUserProjectArea("~/Library/Application Support/X/node_modules"))
        #expect(!CleanupAnalyzer.isUserProjectArea("~/dev/Thing.app/Contents/node_modules"))
        #expect(!CleanupAnalyzer.isUserProjectArea("/opt/homebrew/lib/node_modules"))
    }

    @Test func doesNotDescendIntoAppBundles() {
        let modules = dir("node_modules", [file("electron.js", 80_000_000)])
        let app = dir("Slack.app", [dir("Contents", [dir("Resources", [dir("app", [file("package.json", 10), modules])])])], kind: .package)
        let root = dir(home, [dir("Applications", [app])])
        #expect(!analyze(root).flatMap(\.findings).contains { $0.node === modules })
    }

    @Test func cachesAndDerivedDataAreFound() throws {
        let derived = dir("DerivedData", [file("x", 900_000_000)])
        let spotify = dir("com.spotify.client", [file("y", 300_000_000)])
        let root = dir(home, [dir("Library", [
            dir("Developer", [dir("Xcode", [derived])]),
            dir("Caches", [spotify, dir("tiny", [file("z", 10)])]),
        ])])
        let sections = analyze(root)
        #expect(sections.first { $0.group.id == "dev.deriveddata" }?.totalSize == 900_000_000)
        let caches = try #require(sections.first { $0.group.id == "sys.usercaches.item" })
        #expect(caches.findings.count == 1, "items below the minimum size are ignored")
        #expect(sections.first?.safety == .safe, "safe sections are listed first")
    }

    @Test func protectedLocationsAreSkipped() {
        let mail = dir("Mail", [dir("V10", [dir("node_modules", [file("a", 50_000_000)])])])
        let root = dir(home, [dir("Library", [mail])])
        #expect(analyze(root).isEmpty)
    }

    @Test func oldInstallersAndForgottenFolders() throws {
        let dmg = file("Tool.dmg", 200_000_000, daysAgo: 60)
        let freshDmg = file("New.dmg", 200_000_000, daysAgo: 1)
        let oldVideo = file("lecture.mp4", 400_000_000, daysAgo: 400)
        let archive = dir("Old Project 2019", [file("big.psd", 700_000_000, daysAgo: 800)], daysAgo: 800)
        let root = dir(home, [
            dir("Downloads", [dmg, freshDmg, oldVideo]),
            dir("Documents", [archive]),
        ])
        let sections = analyze(root)
        let installers = try #require(sections.first { $0.group.id == "downloads.installers" })
        #expect(installers.findings.map(\.node) == [dmg])
        #expect(sections.first { $0.group.id == "downloads.old" }?.findings.first?.node === oldVideo)
        #expect(sections.first { $0.group.id == "folders.forgotten" }?.findings.first?.node === archive)
    }

    @Test func oldJetBrainsVersions() throws {
        let old = dir("Rider2023.3", [file("a", 400_000_000)])
        let new = dir("Rider2024.2", [file("a", 400_000_000)])
        let root = dir(home, [dir("Library", [dir("Application Support", [dir("JetBrains", [old, new])])])])
        let section = try #require(analyze(root).first { $0.group.id == "jetbrains.old" })
        #expect(section.findings.map(\.node) == [old])
        #expect(CleanupAnalyzer.splitVersion("IntelliJIdea2024.1")?.1 == [2024, 1])
        #expect(CleanupAnalyzer.splitVersion("Toolbox") == nil)
    }
}

@Suite("Treemap layout")
struct TreemapTests {
    @Test func squarifyFillsTheRectangleExactly() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let raw: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let total = raw.reduce(0, +)
        let values = raw.map { $0 / total * Double(rect.width * rect.height) }
        let rects = TreemapLayout.squarify(values: values, in: rect)
        #expect(rects.count == values.count)
        let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(area - Double(rect.width * rect.height)) < 1)
        for (r, v) in zip(rects, values) {
            #expect(abs(Double(r.width * r.height) - v) < 0.5)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
        // No two rectangles overlap.
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
        // Squarified: aspect ratios stay reasonable.
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        #expect(worst < 4)
    }

    @Test func nestedLayoutAggregatesTinyChildren() {
        let many = (0..<500).map { file("f\($0)", 10) }
        let root = dir("/r", [dir("big", [file("a", 1_000_000), file("b", 500_000)]), dir("many", many)])
        let cells = TreemapLayout(maxDepth: 4).layout(root: root, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(cells.contains { $0.node.name == "big" && !$0.isLeaf })
        #expect(cells.contains { $0.node.name == "a" && $0.isLeaf })
        #expect(cells.count < 50, "tiny files are merged instead of drawn one by one")
        let extras = TreemapLayout().layout(root: root, in: CGRect(x: 0, y: 0, width: 400, height: 300),
                                            extraBlocks: [FileNode(name: "Free space", kind: .synthetic, size: 3_000_000)])
        #expect(extras.contains { $0.node.isSynthetic })
        #expect(TreemapLayout().layout(root: root, in: .zero).isEmpty)
    }
}

@Suite("Duplicates")
struct DuplicateTests {
    @Test func findsIdenticalContentOnly() throws {
        let tmp = try TemporaryDirectory()
        try tmp.write("a/copy1.bin", bytes: 300_000, fill: 7)
        try tmp.write("b/copy2.bin", bytes: 300_000, fill: 7)
        try tmp.write("c/copy3.bin", bytes: 300_000, fill: 7)
        try tmp.write("d/different.bin", bytes: 300_000, fill: 8)
        try tmp.write("e/small1.txt", bytes: 2_000, fill: 1)
        try tmp.write("e/small2.txt", bytes: 2_000, fill: 1)
        // Same head and tail, different middle: must not match.
        var bytes = [UInt8](repeating: 9, count: 400_000)
        try Data(bytes).write(to: tmp.url.appendingPathComponent("m1.bin"))
        bytes[200_000] = 1
        try Data(bytes).write(to: tmp.url.appendingPathComponent("m2.bin"))

        let root = try DiskScanner().scan(path: tmp.path)
        let groups = DuplicateFinder(minimumSize: 100_000).findDuplicates(in: root)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.files.count == 3)
        #expect(group.wastedBytes == group.fileSize * 2)
        #expect(group.suggestedOriginal != nil)

        let small = DuplicateFinder(minimumSize: 1_000).findDuplicates(in: root)
        #expect(small.count == 2)
    }
}

@Suite("Apps")
struct AppInventoryTests {
    @Test func bundleIdentifiersFromFolderNames() {
        #expect(AppInventory.bundleIdentifier(fromFolderName: "com.spotify.client") == "com.spotify.client")
        #expect(AppInventory.bundleIdentifier(fromFolderName: "WEHT2JH2PR.com.vendor.app.Helper") == "com.vendor.app.Helper")
        #expect(AppInventory.bundleIdentifier(fromFolderName: "group.com.vendor.shared") == "com.vendor.shared")
        #expect(AppInventory.bundleIdentifier(fromFolderName: "com.vendor.app.plist") == "com.vendor.app")
        #expect(AppInventory.bundleIdentifier(fromFolderName: "Google") == nil)
        #expect(AppInventory.bundleIdentifier(fromFolderName: "Some Folder.v2.x") == nil)
    }

    @Test func helpersBelongToTheirApp() {
        let index = ["com.vendor.app": 0, "org.other.tool": 1]
        #expect(AppInventory.owningApp("com.vendor.app.widget", installed: Set(index.keys), index: index) == 0)
        #expect(AppInventory.owningApp("org.other.tool", installed: Set(index.keys), index: index) == 1)
        #expect(AppInventory.owningApp("net.unknown.thing", installed: Set(index.keys), index: index) == nil)
    }

    @Test func detectsLeftoversAndAttributesData() {
        let library = dir("Library", [
            dir("Containers", [dir("com.vendor.app", [file("d", 5_000_000)]), dir("com.gone.app", [file("d", 7_000_000)])]),
            dir("Application Support", [dir("Vendor App", [file("x", 3_000_000)]), dir("com.apple.foo", [file("x", 1)])]),
        ])
        let root = dir(home, [library])
        var apps = [AppInfo(path: "/Applications/Vendor App.app", name: "Vendor App", bundleID: "com.vendor.app", version: "1",
                            size: 100, lastUsed: nil, isSystem: false, isAppStore: false)]
        let leftovers = AppInventory.analyzeLibrary(apps: &apps, tree: root, home: home)
        #expect(leftovers.map(\.bundleID) == ["com.gone.app"])
        #expect(apps[0].dataSize == 8_000_000)
        #expect(apps[0].dataPaths.count == 2)
        #expect(apps[0].lastUsed != nil && apps[0].lastUsedIsEstimate)
    }
}

@Suite("History & insights")
struct HistoryTests {
    @Test func comparisonFindsMostSpecificGrowth() {
        let before = dir("/r", [dir("a", [dir("b", [file("x", 200_000_000)]), file("y", 100_000_000)])])
        let after = dir("/r", [dir("a", [dir("b", [file("x", 900_000_000)]), file("y", 100_000_000)])])
        let changes = ScanComparison.changes(from: ScanSnapshot(root: before), to: ScanSnapshot(root: after))
        #expect(changes.first?.path == "a/b")
        #expect(changes.first?.delta == 700_000_000)
        #expect(!changes.contains { $0.path == "a" }, "parent explained by child is dropped")
    }

    @Test func storeKeepsHistory() throws {
        let tmp = try TemporaryDirectory()
        let store = ScanHistoryStore(directory: tmp.url)
        let tree = dir("/r", [dir("a", [file("x", 100_000_000)])])
        #expect(store.record(ScanSnapshot(root: tree)) == nil)
        let previous = store.record(ScanSnapshot(root: tree))
        #expect(previous?.totalSize == 100_000_000)
        #expect(store.load(rootPath: "/r").count == 2)
        for _ in 0..<30 { store.record(ScanSnapshot(root: tree), keep: 5) }
        #expect(store.load(rootPath: "/r").count == 5)
    }

    @Test func parsesDockerSystemDF() {
        let output = """
        {"Active":"2","Reclaimable":"1.2GB (40%)","Size":"3GB","TotalCount":"10","Type":"Images"}
        {"Active":"1","Reclaimable":"0B","Size":"20MB","TotalCount":"3","Type":"Containers"}
        not json
        """
        let usage = DockerUsage.parse(jsonLines: output, context: "orbstack")
        #expect(usage?.rows.count == 2)
        #expect(usage?.rows.first?.reclaimable == "1.2GB (40%)")
        #expect(DockerUsage.parse(jsonLines: "") == nil)
    }
}

@Suite("Sunburst layout")
struct SunburstTests {
    @Test func anglesPartitionTheCircle() {
        let root = dir("/r", [dir("a", [file("x", 600), file("y", 200)]), file("b", 200)])
        let segments = SunburstLayout(maxDepth: 3).layout(root: root)
        let ring1 = segments.filter { $0.depth == 1 }
        #expect(abs(ring1.reduce(0) { $0 + $1.span } - 2 * .pi) < 1e-9)
        let a = try! #require(ring1.first { $0.node.name == "a" })
        #expect(abs(a.span - 2 * .pi * 0.8) < 1e-9)
        let ring2 = segments.filter { $0.depth == 2 }
        #expect(ring2.count == 2)
        #expect(ring2.allSatisfy { $0.startAngle >= a.startAngle - 1e-9 && $0.endAngle <= a.endAngle + 1e-9 })
        #expect(SunburstLayout.segment(in: segments, depth: 1, angle: 0.1)?.node.name == "a")
        #expect(SunburstLayout.segment(in: segments, depth: 1, angle: 2 * .pi - 0.1)?.node.name == "b")
        #expect(SunburstLayout.segment(in: segments, depth: 1, angle: -0.1)?.node.name == "b")
    }

    @Test func tinyChildrenAreAggregatedAndDepthLimited() {
        let root = dir("/r", [file("big", 1_000_000)] + (0..<100).map { file("t\($0)", 1) } + [dir("d", [dir("e", [file("f", 10)])])])
        let segments = SunburstLayout(maxDepth: 1, minimumAngle: 0.01).layout(root: root)
        #expect(segments.allSatisfy { $0.depth == 1 })
        #expect(segments.contains { $0.isAggregate && $0.aggregateCount >= 100 })
    }
}

@Suite("Treemap interaction")
struct TreemapInteractionTests {
    @Test func hitTestingFindsDeepestCellAndZoomTargets() throws {
        let leaf = file("movie.mp4", 800_000)
        let folder = dir("Movies", [leaf, file("clip.mov", 200_000)])
        let root = dir("/r", [folder, file("other.bin", 1_000_000)])
        let cells = TreemapLayout(maxDepth: 4).layout(root: root, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let folderCell = try #require(cells.first { $0.node === folder })
        let leafCell = try #require(cells.first { $0.node === leaf })
        let hit = try #require(TreemapLayout.cell(at: CGPoint(x: leafCell.rect.midX, y: leafCell.rect.midY), in: cells))
        #expect(hit.node === leaf, "the deepest cell wins over its folder")
        #expect(TreemapLayout.zoomTarget(for: hit, root: root) === folder, "double-clicking a file opens its folder")
        #expect(TreemapLayout.zoomTarget(for: folderCell, root: root) === folder)
        let other = try #require(cells.first { $0.node.name == "other.bin" })
        #expect(TreemapLayout.zoomTarget(for: other, root: root) == nil, "file at the root has nothing to open")
        #expect(TreemapLayout.cell(at: CGPoint(x: -5, y: -5), in: cells) == nil)
    }
}
