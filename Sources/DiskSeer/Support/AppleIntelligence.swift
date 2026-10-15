import DiskSeerCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional second opinion from Apple's on-device foundation model.
enum AppleIntelligence {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static var unavailableReason: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return ""
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return "This Mac does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to get a second opinion."
            case .modelNotReady: return "The Apple Intelligence model is still downloading."
            @unknown default: return "Apple Intelligence is unavailable."
            }
        }
        #else
        return "Apple Intelligence is not available on this system."
        #endif
    }

    /// Model output may contain inline Markdown (bold, code).
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// Builds a compact description of the item for the language model.
    static func prompt(for node: FileNode, local: Classification) -> String {
        var lines: [String] = []
        lines.append("Path: \(ScanLocation.canonicalPath(node.path).abbreviatingHome)")
        lines.append("Type: \(node.isContainer ? "folder" : "file")\(node.kind == .package ? " (bundle)" : "")")
        lines.append("Size on disk: \(ByteFormat.string(node.size))")
        if node.isContainer { lines.append("Files inside: \(node.fileCount)") }
        lines.append("Last modified anywhere inside: \(AgeFormat.relative(node.newestModified))")
        if node.isContainer {
            let top = node.sortedChildren.prefix(12).map { "\($0.name)\($0.isContainer ? "/" : "") \(ByteFormat.string($0.size))" }
            lines.append("Largest entries: \(top.joined(separator: "; "))")
        }
        lines.append("Local classifier guess: \(local.category.displayName) — \(local.label) (\(Int(local.confidence * 100))% confidence)")
        return lines.joined(separator: "\n")
    }

    static var instructions: String {
        let language = Locale.preferredLanguages.first.flatMap { Locale(identifier: "en").localizedString(forIdentifier: $0) } ?? "English"
        return """
        You are DiskSeer, a macOS storage expert. Given facts about a file or folder on a Mac, explain in at most 4 short \
        sentences what it most likely is (which app or tool created it and why), whether removing it is safe, what would \
        happen afterwards, and the proper way to reclaim the space (an app setting, the tool's own cleanup command, or \
        DiskSeer's "Move to Trash"). Never suggest `rm -rf` or other permanent deletion commands. Be concrete and \
        cautious: if the item may contain personal data or app state, say so. Trust the local classifier's label when its \
        confidence is high. If the name does not clearly identify the tool, say you are not sure instead of guessing a product. Answer in \(language). Do not use markdown headings.
        """
    }

    /// A short, prioritized cleanup plan for the whole scan.
    static func summarize(volume: VolumeInfo?, scanned: Int64, categories: [(category: FileCategory, size: Int64)],
                          sections: [FindingSection], apps: [AppInfo]) async throws -> String {
        var lines: [String] = []
        if let volume {
            lines.append("Disk: \(ByteFormat.string(volume.totalCapacity)) total, \(ByteFormat.string(volume.availableCapacity)) free (\(Int(volume.usedFraction * 100))% used).")
        }
        lines.append("Scanned: \(ByteFormat.string(scanned)).")
        lines.append("Space by kind: " + categories.prefix(10).map { "\($0.category.displayName) \(ByteFormat.string($0.size))" }.joined(separator: ", "))
        lines.append("Cleanup findings (title, size, safety):")
        for section in sections.sorted(by: { $0.totalSize > $1.totalSize }).prefix(15) {
            lines.append("- \(section.group.title): \(ByteFormat.string(section.totalSize)), \(section.safety.title)")
        }
        let unused = apps.filter { !$0.isSystem && ($0.lastUsed.map { Date().timeIntervalSince($0) > 180 * 86_400 } ?? false) }
        if !unused.isEmpty {
            lines.append("Apps unused for 6+ months: " + unused.prefix(8).map { "\($0.name) \(ByteFormat.string($0.totalSize))" }.joined(separator: ", "))
        }
        #if canImport(FoundationModels)
        let language = Locale.preferredLanguages.first.flatMap { Locale(identifier: "en").localizedString(forIdentifier: $0) } ?? "English"
        let session = LanguageModelSession(instructions: """
            You are DiskSeer, a macOS storage advisor. From the scan facts, write a prioritized plan of 3 to 5 short bullet \
            points (start each with "• ") telling the user what to clean first and why, biggest safe wins first, then \
            items to review. Mention concrete sizes. Never recommend deleting system files or using rm -rf. Answer in \(language).
            """)
        return try await session.respond(to: lines.joined(separator: "\n")).content
        #else
        throw NSError(domain: "DiskSeer", code: 1, userInfo: [NSLocalizedDescriptionKey: unavailableReason])
        #endif
    }

    static func explain(_ node: FileNode, local: Classification) async throws -> String {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt(for: node, local: local))
        return response.content
        #else
        throw NSError(domain: "DiskSeer", code: 1, userInfo: [NSLocalizedDescriptionKey: unavailableReason])
        #endif
    }
}
