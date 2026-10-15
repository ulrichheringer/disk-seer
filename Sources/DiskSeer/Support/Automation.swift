import AppKit
import DiskSeerCore

/// Scripted runs used for automated visual checks (see README).
///
/// Environment variables:
/// - `DISKSEER_SCAN`: path to scan on launch.
/// - `DISKSEER_SNAPSHOTS`: comma separated sections to capture (e.g. "overview,explorer,smartClean").
/// - `DISKSEER_SNAPSHOT_DIR`: where PNGs are written.
/// - `DISKSEER_ZOOM` / `DISKSEER_SELECT`: path relative to the scan root to zoom into / select.
/// - `DISKSEER_VIEW=rings`: show the sunburst instead of the treemap.
/// - `DISKSEER_DUPLICATES=1`: run the duplicate finder before capturing.
/// - `DISKSEER_EXIT=1`: quit when done.
@MainActor
enum Automation {
    private static var started = false

    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard !started, let path = env["DISKSEER_SCAN"] else { return }
        started = true
        Task { await run(model: model, path: path, env: env) }
    }

    private static func run(model: AppModel, path: String, env: [String: String]) async {
        let dir = URL(fileURLWithPath: env["DISKSEER_SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sections = (env["DISKSEER_SNAPSHOTS"] ?? "").split(separator: ",").compactMap {
            AppModel.Section(rawValue: $0.trimmingCharacters(in: .whitespaces))
        }

        try? await Task.sleep(for: .milliseconds(800))
        model.startScan(path: path)
        while model.phase == .scanning { try? await Task.sleep(for: .milliseconds(200)) }
        for _ in 0..<150 where model.appsLoading || model.dockerLoading { try? await Task.sleep(for: .milliseconds(200)) }

        if let zoom = env["DISKSEER_ZOOM"], let node = model.root?.descendant(atRelativePath: zoom) { model.zoom(into: node) }
        if let select = env["DISKSEER_SELECT"], let node = model.root?.descendant(atRelativePath: select) { model.selection = node }
        if env["DISKSEER_VIEW"] == "rings" { model.visualization = .rings }
        if env["DISKSEER_DUPLICATES"] == "1" {
            model.findDuplicates()
            while model.duplicateState == .running { try? await Task.sleep(for: .milliseconds(200)) }
        }
        for section in sections {
            model.section = section
            try? await Task.sleep(for: .milliseconds(1500))
            capture(to: dir.appendingPathComponent("\(section.rawValue).png"))
        }
        if env["DISKSEER_EXIT"] == "1" { NSApp.terminate(nil) }
    }

    /// Captures the main window as it appears on screen.
    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.frame.width > 400 }) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
        print("snapshot: \(url.path)")
    }
}
