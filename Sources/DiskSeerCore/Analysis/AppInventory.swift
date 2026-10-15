import CoreServices
import Foundation

/// An installed application.
public struct AppInfo: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let size: Int64
    public var lastUsed: Date?
    /// True when `lastUsed` was inferred from the app's own data instead of Spotlight.
    public var lastUsedIsEstimate = false
    public let isSystem: Bool
    public let isAppStore: Bool
    /// Size of the app's data in ~/Library (containers, caches, support files).
    public var dataSize: Int64 = 0
    public var dataPaths: [String] = []

    public var totalSize: Int64 { size + dataSize }
}

/// Files in ~/Library that belong to an app that is not installed any more.
public struct AppLeftover: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let bundleID: String
    public let location: String
    public let size: Int64
}

public enum AppInventory {
    public static var applicationFolders: [String] {
        ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"]
    }

    /// Find installed apps (two levels deep, e.g. /Applications/Utilities/*.app).
    public static func installedApps(sizesFrom tree: FileNode? = nil, measureMissing: Bool = true) -> [AppInfo] {
        var bundles: [String] = []
        let fm = FileManager.default
        for folder in applicationFolders {
            guard let items = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for item in items {
                let path = folder + "/" + item
                if item.hasSuffix(".app") {
                    bundles.append(path)
                } else if let sub = try? fm.contentsOfDirectory(atPath: path) {
                    bundles += sub.filter { $0.hasSuffix(".app") }.map { path + "/" + $0 }
                }
            }
        }
        let results = UnsafeMutableBufferPointer<AppInfo?>.allocate(capacity: bundles.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: bundles.count) { index in
            results[index] = appInfo(at: bundles[index], tree: tree, measure: measureMissing)
        }
        return results.compactMap { $0 }.sorted { $0.size > $1.size }
    }

    static func appInfo(at path: String, tree: FileNode?, measure: Bool) -> AppInfo? {
        let infoURL = URL(fileURLWithPath: path + "/Contents/Info.plist")
        let plist = (try? Data(contentsOf: infoURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? [:]
        let bundleID = plist["CFBundleIdentifier"] as? String
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)

        var size: Int64 = 0
        if let node = tree?.node(atPath: path) ?? tree?.node(atPath: ScanLocation.dataVolume + path) {
            size = node.size
        } else if measure {
            size = (try? DiskScanner(options: ScanOptions(parallelDepth: 0)).scan(path: path).size) ?? 0
        }
        let isSystem = path.hasPrefix("/System/") || (bundleID?.hasPrefix("com.apple.") ?? false)
        let isAppStore = FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
        return AppInfo(path: path, name: name, bundleID: bundleID, version: version, size: size,
                       lastUsed: lastUsedDate(path), isSystem: isSystem, isAppStore: isAppStore)
    }

    /// Spotlight's "Last opened" date of a file or app.
    public static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        if let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { return date }
        if let dates = MDItemCopyAttribute(item, "kMDItemUsedDates" as CFString) as? [Date], let last = dates.max() { return last }
        return nil
    }

    /// Library locations where apps keep data keyed by bundle identifier.
    static let libraryLocations: [(String, String)] = [
        ("Library/Containers", "Sandbox container"),
        ("Library/Group Containers", "Group container"),
        ("Library/Caches", "Cache"),
        ("Library/Application Support", "Support files"),
        ("Library/HTTPStorages", "Network storage"),
        ("Library/WebKit", "WebKit data"),
        ("Library/Saved Application State", "Saved state"),
        ("Library/Logs", "Logs"),
        ("Library/Application Scripts", "Scripts"),
        ("Library/Preferences", "Preferences"),
    ]

    /// Attach per-app data sizes and detect leftovers of uninstalled apps.
    public static func analyzeLibrary(apps: inout [AppInfo], tree: FileNode?, home: String = NSHomeDirectory()) -> [AppLeftover] {
        let installedIDs = Set(apps.compactMap { $0.bundleID?.lowercased() })
        var indexByID: [String: Int] = [:]
        var indexByName: [String: Int] = [:]
        for (i, app) in apps.enumerated() {
            if let id = app.bundleID?.lowercased() { indexByID[id] = i }
            guard !app.isSystem else { continue }
            let bundleName = ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            for name in [app.name.lowercased(), bundleName] where name.count >= 3 { indexByName[name] = i }
        }
        var newestActivity: [Int: TimeInterval] = [:]
        func noteActivity(_ index: Int, path: String, node: FileNode?) {
            var stamp = node?.newestModified ?? 0
            if stamp == 0 {
                var st = stat()
                if lstat(path, &st) == 0 { stamp = TimeInterval(st.st_mtimespec.tv_sec) }
            }
            newestActivity[index] = max(newestActivity[index] ?? 0, stamp)
        }

        var leftovers: [AppLeftover] = []
        let fm = FileManager.default
        for (relative, label) in libraryLocations {
            let base = home + "/" + relative
            let treeDir = tree?.node(atPath: base) ?? tree?.node(atPath: ScanLocation.dataVolume + base)
            let entries: [(String, Int64, FileNode?)]
            if let treeDir {
                entries = treeDir.children.map { ($0.name, $0.size, $0) }
            } else {
                entries = ((try? fm.contentsOfDirectory(atPath: base)) ?? []).map { ($0, 0, nil) }
            }
            for (name, size, node) in entries {
                guard let bundleID = bundleIdentifier(fromFolderName: name) else {
                    // Folders named after the app ("Code", "Slack", "Spotify") in Application Support / Caches.
                    if relative == "Library/Application Support" || relative == "Library/Caches",
                       let owner = indexByName[name.lowercased()] {
                        apps[owner].dataSize += size
                        apps[owner].dataPaths.append(base + "/" + name)
                        noteActivity(owner, path: base + "/" + name, node: node)
                    }
                    continue
                }
                let lower = bundleID.lowercased()
                if lower.hasPrefix("com.apple.") || lower.hasPrefix("apple.") || lower.hasPrefix("group.com.apple") { continue }
                if let owner = owningApp(lower, installed: installedIDs, index: indexByID) {
                    apps[owner].dataSize += size
                    apps[owner].dataPaths.append(base + "/" + name)
                    noteActivity(owner, path: base + "/" + name, node: node)
                } else if relative == "Library/Preferences" {
                    continue // preference files are tiny; not worth reporting
                } else if !isKnownNonAppIdentifier(lower) {
                    leftovers.append(AppLeftover(path: base + "/" + name, bundleID: bundleID, location: label, size: size))
                }
            }
        }
        for (index, stamp) in newestActivity where apps[index].lastUsed == nil && stamp > 0 {
            apps[index].lastUsed = Date(timeIntervalSince1970: stamp)
            apps[index].lastUsedIsEstimate = true
        }
        return leftovers.sorted { $0.size > $1.size }
    }

    /// "WEHT2JH2PR.com.vendor.app" / "group.com.vendor.app" / "com.vendor.app.plist" -> "com.vendor.app"
    public static func bundleIdentifier(fromFolderName raw: String) -> String? {
        var name = raw
        if name.hasSuffix(".plist") || name.hasSuffix(".savedState") || name.hasSuffix(".binarycookies") {
            name = (name as NSString).deletingPathExtension
        }
        var parts = name.split(separator: ".").map(String.init)
        // Team identifier prefix (10 uppercase alphanumerics).
        if let first = parts.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            parts.removeFirst()
        }
        if parts.first == "group" { parts.removeFirst() }
        guard parts.count >= 3 else { return nil }
        let tlds: Set<String> = ["com", "org", "net", "io", "dev", "app", "co", "me", "de", "us", "uk", "ru", "jp", "cn", "info", "tv", "ai", "so", "sh", "cc", "br", "fr", "ch", "at", "nl", "it", "es", "se", "pl", "ca", "au", "eu", "xyz", "pro", "studio", "tech", "inc"]
        guard tlds.contains(parts[0].lowercased()) else { return nil }
        guard !parts.contains(where: \.isEmpty), !name.contains(" ") else { return nil }
        return parts.joined(separator: ".")
    }

    static func owningApp(_ id: String, installed: Set<String>, index: [String: Int]) -> Int? {
        if let i = index[id] { return i }
        // Helpers/extensions: com.vendor.app.helper belongs to com.vendor.app.
        var parts = id.split(separator: ".")
        while parts.count > 2 {
            parts.removeLast()
            if let i = index[parts.joined(separator: ".")] { return i }
        }
        // Same vendor & product prefix (com.vendor.app vs com.vendor.app-beta).
        for (candidate, i) in index where id.hasPrefix(candidate) || candidate.hasPrefix(id) {
            return i
        }
        return nil
    }

    /// Identifiers that belong to frameworks, CLIs or agents rather than apps.
    static func isKnownNonAppIdentifier(_ id: String) -> Bool {
        let fragments = ["crashpad", "sparkle", "shipit", "update", "helper", "agent", "daemon", "launcher", "plugin", "framework", "keystone", "cache", "sentry", "squirrel"]
        if fragments.contains(where: { id.contains($0) }) { return true }
        let vendors = ["com.google.", "com.microsoft.", "org.mozilla.", "com.adobe.", "com.jetbrains."]
        return vendors.contains { id.hasPrefix($0) } && id.split(separator: ".").count <= 2
    }
}
