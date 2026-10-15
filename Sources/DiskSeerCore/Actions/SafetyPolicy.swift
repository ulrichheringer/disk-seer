import Foundation

/// Decides whether DiskSeer may move an item to the Trash.
///
/// DiskSeer never deletes permanently: removal always goes through the Trash
/// so the user can restore anything. On top of that, this policy refuses
/// paths whose removal could damage macOS, apps or irreplaceable user data.
public struct SafetyPolicy: Sendable {
    public let home: String
    /// Folders whose contents are always allowed (used for sandboxes / tests).
    public let allowedRoots: [String]

    public init(home: String = NSHomeDirectory(), allowedRoots: [String] = []) {
        self.home = home
        self.allowedRoots = allowedRoots.map { SafetyPolicy.canonical($0) }
    }

    static func canonical(_ raw: String) -> String {
        var path = ScanLocation.canonicalPath(DiskScanner.normalize(raw))
        for firmlink in ["/var", "/tmp", "/etc"] where path == firmlink || path.hasPrefix(firmlink + "/") {
            path = "/private" + path
        }
        return path
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)

        public var isAllowed: Bool { self == .allowed }
        public var reason: String? {
            if case let .denied(reason) = self { return reason }
            return nil
        }
    }

    /// Folders that must never be removed themselves (their contents may be).
    private var protectedExact: Set<String> {
        let h = home
        return [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/bin", "/cores", "/dev", "/etc",
            "/opt", "/private", "/sbin", "/tmp", "/usr", "/usr/local", "/var", "/opt/homebrew", "/private/tmp", "/private/var", "/private/etc",
            "/System/Volumes/Data", "/Users/Shared",
            h, h + "/Library", h + "/Documents", h + "/Desktop", h + "/Downloads", h + "/Pictures", h + "/Movies",
            h + "/Music", h + "/Public", h + "/Applications", h + "/.Trash",
            h + "/Library/Application Support", h + "/Library/Caches", h + "/Library/Containers",
            h + "/Library/Group Containers", h + "/Library/Preferences", h + "/Library/Logs",
            h + "/Library/Developer", h + "/Library/CloudStorage", h + "/Library/Mobile Documents",
        ]
    }

    /// Nothing at or below these paths may be removed.
    private var protectedTrees: [String] {
        let h = home
        return [
            "/System", "/bin", "/sbin", "/usr/bin", "/usr/lib", "/usr/libexec", "/usr/sbin", "/usr/share",
            "/private/var/db", "/private/var/vm", "/private/var/folders", "/private/etc", "/dev",
            "/Library/Apple", "/Library/Extensions", "/Library/Keychains", "/Library/Security",
            "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", "/Library/Preferences",
            "/Library/Developer/CommandLineTools",
            h + "/Library/Keychains", h + "/Library/Mail", h + "/Library/Messages/chat.db",
            h + "/Library/Mobile Documents", h + "/Library/Preferences", h + "/Library/Accounts",
            h + "/Library/Biome", h + "/Library/Metadata", h + "/Library/Sharing", h + "/Library/IdentityServices",
            h + "/Library/Calendars", h + "/Library/Reminders", h + "/Library/Safari/Bookmarks.plist",
            h + "/Library/Application Support/AddressBook", h + "/Library/Group Containers/group.com.apple.notes",
            h + "/.ssh", h + "/.gnupg",
        ]
    }

    /// Package types whose *internals* must not be touched individually.
    private let managedPackageExtensions: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary", "app", "framework", "fcpbundle", "logicx", "imovielibrary"]

    public func verdict(forPath rawPath: String) -> Verdict {
        let path = SafetyPolicy.canonical(rawPath)
        if path.isEmpty || path == "/" { return .denied("The disk root cannot be removed.") }
        for root in allowedRoots where path.hasPrefix(root + "/") { return .allowed }
        if protectedExact.contains(path) {
            return .denied("\(path.abbreviatingHome) is an essential folder. Remove its contents instead.")
        }
        for tree in protectedTrees where path == tree || path.hasPrefix(tree + "/") {
            return .denied("\(path.abbreviatingHome) belongs to macOS or holds irreplaceable data.")
        }
        let components = path.split(separator: "/")
        if components.count < 2 {
            return .denied("Top level folders cannot be removed.")
        }
        // Items inside an app bundle or a Photos/Music library must be managed as a whole.
        for component in components.dropLast() {
            let ext = (String(component) as NSString).pathExtension.lowercased()
            if managedPackageExtensions.contains(ext) {
                return .denied("This item lives inside \(component). Remove the whole bundle or manage it in its app.")
            }
        }
        // Built-in apps.
        if path.hasPrefix("/System/Applications/") { return .denied("Built-in macOS apps cannot be removed.") }
        return .allowed
    }
}
