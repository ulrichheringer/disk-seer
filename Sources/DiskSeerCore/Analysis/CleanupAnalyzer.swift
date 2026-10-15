import Foundation

/// A group of related cleanup suggestions ("Xcode DerivedData", "Application caches"...).
public struct FindingGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let category: FileCategory
    public let command: String?

    public init(id: String, title: String, summary: String, category: FileCategory, command: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.command = command
    }
}

/// One item that could be removed to free space.
public struct CleanupFinding: Identifiable, Hashable, Sendable {
    public var id: ObjectIdentifier { node.id }
    public let node: FileNode
    public let group: FindingGroup
    public let title: String
    public let detail: String
    public let safety: CleanupSafety
    public let regenerable: Bool

    public var size: Int64 { node.size }
    public var path: String { node.path }

    public init(node: FileNode, group: FindingGroup, title: String, detail: String, safety: CleanupSafety, regenerable: Bool) {
        self.node = node
        self.group = group
        self.title = title
        self.detail = detail
        self.safety = safety
        self.regenerable = regenerable
    }

    public static func == (lhs: CleanupFinding, rhs: CleanupFinding) -> Bool { lhs.node === rhs.node && lhs.group.id == rhs.group.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(node.id); hasher.combine(group.id) }
}

/// Findings of one group, with totals.
public struct FindingSection: Identifiable, Hashable, Sendable {
    public var id: String { group.id }
    public let group: FindingGroup
    public let findings: [CleanupFinding]
    public var totalSize: Int64 { findings.reduce(0) { $0 + $1.size } }
    /// Safest level among the findings decides how the section is presented.
    public var safety: CleanupSafety { findings.map(\.safety).min() ?? .review }

    public init(group: FindingGroup, findings: [CleanupFinding]) {
        self.group = group
        self.findings = findings
    }
}

/// Walks a classified tree and produces cleanup suggestions.
public struct CleanupAnalyzer: Sendable {
    public struct Settings: Sendable {
        public var minimumSize: Int64 = 1_000_000
        public var staleProjectDays: Double = 30
        public var oldDownloadDays: Double = 90
        public var oldInstallerDays: Double = 14
        public var forgottenFolderDays: Double = 365
        public var forgottenFolderMinimumSize: Int64 = 500_000_000
        public var largeOldFileDays: Double = 180
        public var largeOldFileMinimumSize: Int64 = 500_000_000
        public init() {}
    }

    public let engine: RuleEngine
    public var settings: Settings
    public var now: Date

    public init(engine: RuleEngine = .shared, settings: Settings = Settings(), now: Date = Date()) {
        self.engine = engine
        self.settings = settings
        self.now = now
    }

    private static let groupTitles: [String: String] = [
        "sys.usercaches.item": "Application caches",
        "sys.usercaches.apple": "macOS caches",
        "sys.containercaches": "Sandboxed app caches",
        "sys.containertmp": "Sandboxed app temporary files",
        "proj.nodemodules": "node_modules folders",
        "proj.venv": "Python virtual environments", "proj.venv2": "Python virtual environments", "proj.venv3": "Python virtual environments",
        "proj.cargo": "Rust build folders (target)",
        "proj.gradlebuild": "Gradle build folders",
        "proj.dotnetbin": ".NET build output (bin/obj)", "proj.dotnetobj": ".NET build output (bin/obj)",
        "proj.swiftpm": "SwiftPM build folders (.build)",
        "proj.next": "Next.js build caches",
        "pkg.xdgcacheitem": "Command line tool caches",
        "vm.diskfiles": "Virtual disk images",
        "type.partial": "Incomplete downloads",
        "vm.dockerraw": "Docker Desktop disk", "vm.orbstackdata": "Virtual machine disks",
    ]

    /// Merge groups that describe the same thing (e.g. bin & obj).
    private static let groupAliases: [String: String] = [
        "proj.venv2": "proj.venv", "proj.venv3": "proj.venv", "proj.dotnetobj": "proj.dotnetbin",
        "pkg.pipxdg": "pkg.pip", "pkg.anaconda": "pkg.conda", "pkg.anacondaopt": "pkg.conda",
        "pkg.composerhome": "pkg.composer", "proj.zigcacheold": "proj.zigcache", "proj.cmakerelease": "proj.cmakedebug",
        "proj.deriveddata": "dev.deriveddata", "pkg.lmstudioold": "pkg.lmstudio", "app.slackmas": "app.slackcache",
        "app.onedrive2": "app.onedrive",
    ]

    public func analyze(root: FileNode, apps: [AppInfo] = [], leftovers: [AppLeftover] = []) -> [FindingSection] {
        var findings: [CleanupFinding] = []
        var claimed = Set<ObjectIdentifier>()
        var groups: [String: FindingGroup] = [:]

        func group(for sig: Signature) -> FindingGroup {
            let id = CleanupAnalyzer.groupAliases[sig.id] ?? sig.id
            if let g = groups[id] { return g }
            let base = engine.signature(id: id) ?? sig
            let g = FindingGroup(id: id, title: CleanupAnalyzer.groupTitles[id] ?? base.label,
                                 summary: base.advice?.summary ?? base.explanation, category: base.category,
                                 command: base.advice?.command)
            groups[id] = g
            return g
        }

        // 1. Knowledge base driven findings.
        let rootKey = engine.keyPath(forAbsolutePath: root.path)
        walkSignatures(root, key: rootKey) { node, sig, key in
            guard let advice = sig.advice else { return true }
            if advice.safety == .protected { return false }
            guard sig.reportable else { return node.kind != .package }
            if sig.id.hasPrefix("proj.") && !CleanupAnalyzer.isUserProjectArea(key) { return false }
            let minimum: Int64 = sig.id == "sys.trash" ? 1 : settings.minimumSize
            guard node.size >= minimum else { return false }
            var safety = advice.safety
            var detail = advice.summary
            if sig.id.hasPrefix("proj.") {
                let (adjusted, note) = projectActivity(of: node, base: safety)
                safety = adjusted
                detail = note + " " + detail
            }
            findings.append(CleanupFinding(node: node, group: group(for: sig), title: displayTitle(node: node, sig: sig, key: key),
                                           detail: detail, safety: safety, regenerable: advice.regenerable))
            claimed.insert(node.id)
            return false
        }

        // 2. Old IDE versions (JetBrains) — keep the newest of each product.
        findings += oldJetBrainsVersions(root: root, claimed: &claimed)

        // 3. Downloads: old installers & forgotten downloads.
        findings += downloadsFindings(root: root, claimed: &claimed)

        // 4. Forgotten folders, then large files nobody touched for a long time (outside those folders).
        findings += forgottenFolders(root: root, claimed: &claimed)
        findings += largeOldFiles(root: root, claimed: &claimed)

        // 6. Unused applications & leftovers of uninstalled apps.
        findings += unusedApps(apps, root: root)
        findings += leftoverFindings(leftovers, root: root, claimed: &claimed)

        let grouped = Dictionary(grouping: findings, by: \.group.id)
        return grouped.values.compactMap { items -> FindingSection? in
            guard let first = items.first else { return nil }
            return FindingSection(group: first.group, findings: items.sorted { $0.size > $1.size })
        }
        .filter { $0.totalSize > 0 }
        .sorted { lhs, rhs in
            if lhs.safety != rhs.safety { return lhs.safety < rhs.safety }
            return lhs.totalSize > rhs.totalSize
        }
    }

    /// Project rules (node_modules, target, bin…) only apply to the user's own projects, never to
    /// folders managed by tools (~/.vscode/extensions, ~/.nvm, Homebrew, app bundles…).
    public static func isUserProjectArea(_ key: String) -> Bool {
        var components = key.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return false }
        components.removeLast() // the matched folder itself (may be hidden, e.g. .venv)
        if components.first == "~" {
            components.removeFirst()
            if let first = components.first, ["Library", "Applications"].contains(first) { return false }
        } else if components.first == "Users", components.count >= 2 {
            components.removeFirst(2)
            if let first = components.first, ["Library", "Applications"].contains(first) { return false }
        } else if components.first != "Volumes" {
            return false
        }
        for component in components {
            if component.hasPrefix(".") { return false }
            if component == "node_modules" || component == "site-packages" || component == "vendor" { return false }
            let ext = (String(component) as NSString).pathExtension.lowercased()
            if ScanOptions.defaultPackageExtensions.contains(ext) { return false }
        }
        return true
    }

    /// Depth-first walk calling `visit` for every node that matches a signature.
    /// Return false from `visit` to skip the matched node's subtree.
    private func walkSignatures(_ node: FileNode, key: String, visit: (FileNode, Signature, String) -> Bool) {
        if let sig = engine.match(node: node, key: key) {
            if !visit(node, sig, key) { return }
        }
        guard node.kind == .directory else { return }
        for child in node.children {
            walkSignatures(child, key: engine.childKeyPath(parent: key, name: child.name), visit: visit)
        }
    }

    private func displayTitle(node: FileNode, sig: Signature, key: String) -> String {
        switch sig.matcher {
        case .glob:
            return node.name
        case .directoryName, .directoryWithSibling, .directoryContaining:
            // Show the project the folder belongs to.
            if let parent = node.parent { return "\((parent.name as NSString).lastPathComponent)/\(node.name)" }
            return node.name
        case .fileName, .fileExtension, .packageExtension:
            return node.name
        case .path:
            return sig.label
        }
    }

    /// Dependencies of a project nobody touched recently are safe to remove.
    private func projectActivity(of node: FileNode, base: CleanupSafety) -> (CleanupSafety, String) {
        guard let project = node.parent else { return (base, "") }
        let name = (project.name as NSString).lastPathComponent
        var newest: TimeInterval = project.modified
        for sibling in project.children where sibling !== node {
            if sibling.name.hasPrefix(".") && sibling.name != ".git" { continue }
            newest = max(newest, sibling.newestModified)
        }
        let days = AgeFormat.days(since: newest, now: now)
        if days >= settings.staleProjectDays {
            return (min(base, .safe), "Project \u{201C}\(name)\u{201D} untouched for \(AgeFormat.relative(newest, now: now).replacingOccurrences(of: " ago", with: "")).")
        }
        return (max(base, .review), "Project \u{201C}\(name)\u{201D} is active (changed \(AgeFormat.relative(newest, now: now))).")
    }

    private func node(in root: FileNode, canonical path: String) -> FileNode? {
        if let n = root.node(atPath: path) { return n }
        return root.node(atPath: ScanLocation.dataVolume + path)
    }

    private func oldJetBrainsVersions(root: FileNode, claimed: inout Set<ObjectIdentifier>) -> [CleanupFinding] {
        let home = engine.home
        var result: [CleanupFinding] = []
        let g = FindingGroup(id: "jetbrains.old", title: "Old JetBrains IDE versions",
                             summary: "Settings, caches and logs of IDE versions you upgraded from. The newest version of each IDE is kept.",
                             category: .developer)
        for base in [home + "/Library/Application Support/JetBrains", home + "/Library/Caches/JetBrains", home + "/Library/Logs/JetBrains"] {
            guard let dir = node(in: root, canonical: base) else { continue }
            var byProduct: [String: [(FileNode, [Int])]] = [:]
            for child in dir.children where child.isContainer {
                guard let (product, version) = CleanupAnalyzer.splitVersion(child.name) else { continue }
                byProduct[product, default: []].append((child, version))
            }
            for (_, versions) in byProduct where versions.count > 1 {
                let sorted = versions.sorted { $0.1.lexicographicallyPrecedes($1.1) }
                for (old, _) in sorted.dropLast() where old.size >= settings.minimumSize {
                    // Replace a broader claim (whole JetBrains caches folder) is not needed: we report the specific folder.
                    if claimed.contains(dir.id) { continue }
                    claimed.insert(old.id)
                    result.append(CleanupFinding(node: old, group: g, title: old.name,
                                                 detail: "Superseded by \(sorted.last!.0.name).", safety: .safe, regenerable: false))
                }
            }
        }
        return result
    }

    /// "Rider2024.2" -> ("Rider", [2024, 2])
    static func splitVersion(_ name: String) -> (String, [Int])? {
        guard let firstDigit = name.firstIndex(where: \.isNumber) else { return nil }
        let product = String(name[..<firstDigit])
        guard !product.isEmpty else { return nil }
        let numbers = name[firstDigit...].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        return (product, numbers)
    }

    private func downloadsFindings(root: FileNode, claimed: inout Set<ObjectIdentifier>) -> [CleanupFinding] {
        var result: [CleanupFinding] = []
        let installers = FindingGroup(id: "downloads.installers", title: "Installers in Downloads & Desktop",
                                      summary: "Disk images and installer packages are only needed once; the apps are already installed.",
                                      category: .installers)
        let old = FindingGroup(id: "downloads.old", title: "Old downloads",
                               summary: "Files in Downloads you have not opened for months.", category: .documents)
        let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "msi", "exe", "ipsw", "apk", "appimage"]
        for folder in ["Downloads", "Desktop"] {
            guard let dir = node(in: root, canonical: engine.home + "/" + folder) else { continue }
            for item in dir.children where !claimed.contains(item.id) && item.size >= settings.minimumSize {
                let age = AgeFormat.days(since: max(item.newestModified, item.accessed), now: now)
                if installerExts.contains(item.fileExtension) && age >= settings.oldInstallerDays {
                    claimed.insert(item.id)
                    result.append(CleanupFinding(node: item, group: installers, title: item.name,
                                                 detail: "Downloaded \(AgeFormat.relative(item.modified, now: now)).",
                                                 safety: .review, regenerable: false))
                } else if folder == "Downloads" && age >= settings.oldDownloadDays && item.size >= 10_000_000 {
                    claimed.insert(item.id)
                    result.append(CleanupFinding(node: item, group: old, title: item.name,
                                                 detail: "Last opened \(AgeFormat.relative(max(item.newestModified, item.accessed), now: now)).",
                                                 safety: .review, regenerable: false))
                }
            }
        }
        return result
    }

    private func largeOldFiles(root: FileNode, claimed: inout Set<ObjectIdentifier>) -> [CleanupFinding] {
        let g = FindingGroup(id: "files.largeold", title: "Large files not used in months",
                             summary: "Big files you have not opened or changed for a long time.", category: .other)
        let home = engine.home
        let candidates = root.largestFiles(limit: 300, minimumSize: settings.largeOldFileMinimumSize)
        var result: [CleanupFinding] = []
        for file in candidates where file.kind == .file {
            let path = ScanLocation.canonicalPath(file.path)
            guard path.hasPrefix(home + "/"), !path.hasPrefix(home + "/Library/") else { continue }
            if isClaimed(file, claimed) { continue }
            if [.virtualMachines, .applications, .system].contains(file.category) { continue }
            let age = AgeFormat.days(since: max(file.modified, file.accessed), now: now)
            guard age >= settings.largeOldFileDays else { continue }
            claimed.insert(file.id)
            result.append(CleanupFinding(node: file, group: g, title: file.name,
                                         detail: "\(file.category.displayName) · last used \(AgeFormat.relative(max(file.modified, file.accessed), now: now)).",
                                         safety: .review, regenerable: false))
        }
        return result
    }

    private func forgottenFolders(root: FileNode, claimed: inout Set<ObjectIdentifier>) -> [CleanupFinding] {
        let g = FindingGroup(id: "folders.forgotten", title: "Forgotten folders",
                             summary: "Large folders where nothing changed for over a year. Archive them to an external drive or delete what you no longer need.",
                             category: .other)
        let home = engine.home
        var result: [CleanupFinding] = []
        let skipNames: Set<String> = ["Library", "Applications", "Pictures", "Music", ".Trash"]
        func visit(_ node: FileNode, depth: Int) {
            guard node.isContainer, node.size >= settings.forgottenFolderMinimumSize else { return }
            if claimed.contains(node.id) { return }
            let path = ScanLocation.canonicalPath(node.path)
            if path == home {
                for child in node.children where !skipNames.contains(child.name) { visit(child, depth: depth + 1) }
                return
            }
            guard path.hasPrefix(home + "/") else {
                for child in node.children { visit(child, depth: depth + 1) }
                return
            }
            if node.kind == .package || [.applications, .system, .cloudStorage].contains(node.category) { return }
            let age = AgeFormat.days(since: node.newestModified, now: now)
            if age >= settings.forgottenFolderDays && depth >= 1 && !containsClaim(node, claimed) {
                claimed.insert(node.id)
                result.append(CleanupFinding(node: node, group: g, title: path.abbreviatingHome,
                                             detail: "Nothing changed for \(AgeFormat.relative(node.newestModified, now: now).replacingOccurrences(of: " ago", with: "")) · \(node.fileCount) files.",
                                             safety: .review, regenerable: false))
                return
            }
            if depth < 6 { for child in node.children { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return result
    }

    private func unusedApps(_ apps: [AppInfo], root: FileNode) -> [CleanupFinding] {
        let g = FindingGroup(id: "apps.unused", title: "Apps you haven't used in 6 months",
                             summary: "Uninstall apps you no longer need. Their support files are listed in Applications.", category: .applications)
        return apps.compactMap { app -> CleanupFinding? in
            guard !app.isSystem, app.size >= 50_000_000, let last = app.lastUsed,
                  now.timeIntervalSince(last) > 180 * 86_400 else { return nil }
            let node = root.node(atPath: app.path) ?? root.node(atPath: ScanLocation.dataVolume + app.path)
                ?? FileNode(name: app.path, kind: .package, size: app.size, logicalSize: app.size, modified: last.timeIntervalSince1970)
            return CleanupFinding(node: node, group: g, title: app.name,
                                  detail: "Last opened \(AgeFormat.relative(last.timeIntervalSince1970, now: now)).",
                                  safety: .review, regenerable: false)
        }
    }

    private func leftoverFindings(_ leftovers: [AppLeftover], root: FileNode, claimed: inout Set<ObjectIdentifier>) -> [CleanupFinding] {
        let g = FindingGroup(id: "apps.leftovers", title: "Leftovers of uninstalled apps",
                             summary: "Support files, caches and containers left behind by apps that are no longer installed.",
                             category: .system)
        return leftovers.compactMap { leftover -> CleanupFinding? in
            guard leftover.size >= settings.minimumSize else { return nil }
            let node = root.node(atPath: leftover.path) ?? root.node(atPath: ScanLocation.dataVolume + leftover.path)
                ?? FileNode(name: leftover.path, kind: .directory, size: leftover.size, logicalSize: leftover.size)
            if claimed.contains(node.id) { return nil }
            claimed.insert(node.id)
            return CleanupFinding(node: node, group: g, title: leftover.bundleID,
                                  detail: "\(leftover.location) of \u{201C}\(leftover.bundleID)\u{201D}, which is not installed.",
                                  safety: .review, regenerable: false)
        }
    }

    private func isClaimed(_ node: FileNode, _ claimed: Set<ObjectIdentifier>) -> Bool {
        var cursor: FileNode? = node
        while let c = cursor {
            if claimed.contains(c.id) { return true }
            cursor = c.parent
        }
        return false
    }

    private func containsClaim(_ node: FileNode, _ claimed: Set<ObjectIdentifier>) -> Bool {
        var found = false
        node.walk { n in
            if found { return false }
            if claimed.contains(n.id) { found = true; return false }
            return n.isContainer
        }
        return found
    }
}
