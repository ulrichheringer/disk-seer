import Darwin
import Foundation

/// Indexes `Signature`s for fast lookup while walking large trees.
public final class RuleEngine: @unchecked Sendable {
    public let signatures: [Signature]
    public let home: String
    private var exactPaths: [String: Signature] = [:]
    private var globs: [(pattern: String, slashes: Int, literal: Int, signature: Signature)] = []
    private var directoryNames: [String: [Signature]] = [:]
    private var fileNames: [String: Signature] = [:]
    private var fileExtensions: [String: Signature] = [:]
    private var packageExtensions: [String: Signature] = [:]
    private var byID: [String: Signature] = [:]

    public static let shared = RuleEngine()

    public init(signatures: [Signature] = KnowledgeBase.signatures, home: String = NSHomeDirectory()) {
        self.signatures = signatures
        self.home = home
        for signature in signatures {
            byID[signature.id] = signature
            switch signature.matcher {
            case let .path(p):
                if exactPaths[p] == nil { exactPaths[p] = signature }
            case let .glob(pattern):
                let slashes = pattern.filter { $0 == "/" }.count
                let literal = pattern.filter { $0 != "*" }.count
                globs.append((pattern, slashes, literal, signature))
            case let .directoryName(name), let .directoryWithSibling(name, _), let .directoryContaining(name, _):
                directoryNames[name, default: []].append(signature)
            case let .fileName(name):
                if fileNames[name] == nil { fileNames[name] = signature }
            case let .fileExtension(exts):
                for ext in exts where fileExtensions[ext] == nil { fileExtensions[ext] = signature }
            case let .packageExtension(exts):
                for ext in exts where packageExtensions[ext] == nil { packageExtensions[ext] = signature }
            }
        }
        // Most specific patterns first.
        globs.sort { $0.literal > $1.literal }
        // Contextual directory rules before plain name rules.
        for key in directoryNames.keys {
            directoryNames[key]?.sort { $0.isContextual && !$1.isContextual }
        }
    }

    public func signature(id: String) -> Signature? { byID[id] }

    static let executableSignature = Signature("type.executable", .fileName("*"), .developer, "Executable program",
                                               "A command line program or app binary stored in a bin folder.", inheritance: .none)

    /// The "key path" used for matching: canonical (firmlinked) path with the home folder as "~".
    public func keyPath(forAbsolutePath absolute: String) -> String {
        var p = absolute
        if p == ScanLocation.dataVolume { return "" }
        p = ScanLocation.canonicalPath(p)
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    /// Key path of a child given the parent's key path.
    public func childKeyPath(parent: String, name: String) -> String {
        let candidate = parent.isEmpty ? "/" + name : (parent == "/" ? "/" + name : parent + "/" + name)
        if candidate == home { return "~" }
        return candidate
    }

    /// Find the best signature for `node`, whose key path is `key`.
    /// - Parameter includeFileTypes: when false, generic file-extension rules are skipped.
    public func match(node: FileNode, key: String, includeFileTypes: Bool = true) -> Signature? {
        if let exact = exactPaths[key] { return exact }

        if !globs.isEmpty {
            let slashes = key.utf8.reduce(0) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
            for glob in globs where glob.slashes == slashes {
                if fnmatch(glob.pattern, key, FNM_PATHNAME) == 0 { return glob.signature }
            }
        }

        switch node.kind {
        case .directory, .package:
            let ext = node.fileExtension
            if !ext.isEmpty, let sig = packageExtensions[ext] { return sig }
            if let candidates = directoryNames[node.name] {
                for sig in candidates where contextMatches(sig, node: node) { return sig }
            }
        case .file:
            if let sig = fileNames[node.name] { return sig }
            if includeFileTypes {
                let ext = node.fileExtension
                if !ext.isEmpty, let sig = fileExtensions[ext] { return sig }
                if let parentName = node.parent?.name, ["bin", "sbin", "libexec", "MacOS"].contains(parentName) {
                    return RuleEngine.executableSignature
                }
            }
        case .symlink, .synthetic:
            break
        }
        return nil
    }

    private func contextMatches(_ signature: Signature, node: FileNode) -> Bool {
        switch signature.matcher {
        case let .directoryWithSibling(_, markers):
            guard let siblings = node.parent?.children else { return false }
            return siblings.contains { sibling in sibling !== node && markers.contains { RuleEngine.marker($0, matches: sibling.name) } }
        case let .directoryContaining(_, markers):
            return node.children.contains { child in markers.contains { RuleEngine.marker($0, matches: child.name) } }
        default:
            return true
        }
    }

    static func marker(_ marker: String, matches name: String) -> Bool {
        if marker.hasPrefix("*") { return name.hasSuffix(marker.dropFirst()) }
        return marker == name
    }
}
