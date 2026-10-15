import DiskSeerCore
import Foundation

// diskseer-cli [path] [--findings] [--apps] [--dupes] [--explain <path>]
var arguments = Array(CommandLine.arguments.dropFirst())
var explainPath: String?
if let i = arguments.firstIndex(of: "--explain"), i + 1 < arguments.count {
    explainPath = DiskScanner.normalize(arguments[i + 1])
    arguments.removeSubrange(i...(i + 1))
}
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let target = arguments.first { !$0.hasPrefix("--") } ?? NSHomeDirectory()

func column(_ bytes: Int64) -> String { ByteFormat.string(bytes).padding(toLength: 10, withPad: " ", startingAt: 0) }

let progress = ScanProgress()
let start = Date()
let root: FileNode
do {
    root = try DiskScanner().scan(path: target, progress: progress)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
let classifier = TreeClassifier()
classifier.classify(root: root)
print("Scanned \(root.path): \(ByteFormat.string(root.size)), \(progress.files) files, \(progress.directories) folders, "
    + "\(progress.restricted) restricted, " + String(format: "%.1f s", Date().timeIntervalSince(start)))

print("\nTop folders:")
for child in root.sortedChildren.prefix(15) {
    print("  \(column(child.size)) \(child.name)  [\(child.category.displayName)]")
}

var byCategory: [FileCategory: Int64] = [:]
root.forEach { if $0.kind == .file { byCategory[$0.category, default: 0] += $0.size } }
print("\nBy category:")
for (category, size) in byCategory.sorted(by: { $0.value > $1.value }) {
    print("  \(column(size)) \(category.displayName)")
}

var apps: [AppInfo] = []
var leftovers: [AppLeftover] = []
if flags.contains("--apps") {
    apps = AppInventory.installedApps(sizesFrom: root)
    leftovers = AppInventory.analyzeLibrary(apps: &apps, tree: root)
    print("\nApps (app + data):")
    for app in apps.prefix(15) {
        print("  \(column(app.size)) +\(column(app.dataSize)) \(app.name)")
    }
    print("\nLeftovers of uninstalled apps:")
    for leftover in leftovers.prefix(15) { print("  \(column(leftover.size)) \(leftover.path.abbreviatingHome)") }
}

if flags.contains("--findings") {
    print("\nSmart Clean:")
    for section in CleanupAnalyzer().analyze(root: root, apps: apps, leftovers: leftovers) {
        print("  [\(section.safety.title)] \(section.group.title): \(ByteFormat.string(section.totalSize)) (\(section.findings.count))")
        for finding in section.findings.prefix(3) {
            print("      \(column(finding.size)) \(finding.title) — \(finding.detail)")
        }
    }
}

if flags.contains("--dupes") {
    let groups = DuplicateFinder(minimumSize: 5_000_000).findDuplicates(in: root)
    print("\nDuplicates: \(groups.count) groups, \(ByteFormat.string(groups.reduce(0) { $0 + $1.wastedBytes })) wasted")
    for group in groups.prefix(8) { print("  \(column(group.wastedBytes)) x\(group.files.count) \(group.files[0].name)") }
}

if let explainPath {
    guard let node = root.node(atPath: explainPath) else {
        print("\nNot in the scanned tree: \(explainPath)")
        exit(1)
    }
    let c = classifier.explain(node)
    print("\n\(explainPath):\n  \(c.category.displayName) — \(c.label) (\(Int(c.confidence * 100))%, \(c.source.rawValue))\n  \(c.explanation)")
    for line in c.evidence { print("   • \(line)") }
    if let advice = c.advice { print("  [\(advice.safety.title)] \(advice.summary) \(advice.command ?? "")") }
}
