import AppKit
import DiskSeerCore
import Quartz
import SwiftUI

/// Finder / Terminal helpers.
@MainActor
enum Workspace {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func openInTerminal(_ path: String) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let folder = isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
        let config = NSWorkspace.OpenConfiguration()
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: terminal, configuration: config)
        }
    }

    /// Asks the user for a folder or volume to scan.
    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func icon(for path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        return image
    }

    static func quickLook(_ path: String) {
        QuickLookCoordinator.shared.show(URL(fileURLWithPath: path))
    }
}

/// Minimal Quick Look panel driver.
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}

// MARK: - Colors

extension FileCategory {
    var color: Color {
        let c = rgb
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

extension CleanupSafety {
    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .caution: .red
        case .protected: .gray
        }
    }
}

enum AgePalette {
    /// Color for a "last modified" timestamp: recent = warm, old = cold.
    static func color(for timestamp: TimeInterval, now: Date = Date()) -> Color {
        let days = AgeFormat.days(since: timestamp, now: now)
        switch days {
        case ..<7: return Color(red: 0.93, green: 0.27, blue: 0.25)
        case ..<30: return Color(red: 0.97, green: 0.55, blue: 0.20)
        case ..<90: return Color(red: 0.96, green: 0.78, blue: 0.25)
        case ..<180: return Color(red: 0.55, green: 0.78, blue: 0.32)
        case ..<365: return Color(red: 0.25, green: 0.70, blue: 0.62)
        case ..<730: return Color(red: 0.25, green: 0.52, blue: 0.85)
        default: return Color(red: 0.45, green: 0.36, blue: 0.80)
        }
    }

    static let legend: [(String, Color)] = [
        ("< 1 week", color(for: Date().timeIntervalSince1970 - 86_400)),
        ("< 1 month", color(for: Date().timeIntervalSince1970 - 10 * 86_400)),
        ("< 3 months", color(for: Date().timeIntervalSince1970 - 40 * 86_400)),
        ("< 6 months", color(for: Date().timeIntervalSince1970 - 100 * 86_400)),
        ("< 1 year", color(for: Date().timeIntervalSince1970 - 200 * 86_400)),
        ("< 2 years", color(for: Date().timeIntervalSince1970 - 400 * 86_400)),
        ("older", color(for: Date().timeIntervalSince1970 - 900 * 86_400)),
    ]
}

enum FolderPalette {
    static let colors: [Color] = [
        Color(red: 0.27, green: 0.52, blue: 0.96), Color(red: 0.93, green: 0.47, blue: 0.20), Color(red: 0.24, green: 0.72, blue: 0.52),
        Color(red: 0.86, green: 0.22, blue: 0.32), Color(red: 0.55, green: 0.36, blue: 0.90), Color(red: 0.98, green: 0.78, blue: 0.22),
        Color(red: 0.10, green: 0.62, blue: 0.78), Color(red: 0.95, green: 0.36, blue: 0.55), Color(red: 0.42, green: 0.66, blue: 0.30),
        Color(red: 0.66, green: 0.48, blue: 0.34),
    ]
}

/// Writes tables chosen by the user through a save panel.
@MainActor
enum CSVExport {
    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { field in
                let needsQuotes = field.contains(",") || field.contains("\"") || field.contains("\n")
                let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
                return needsQuotes ? "\"\(escaped)\"" : escaped
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    static func save(rows: [[String]], suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? csv(rows).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
