import AppKit
import DiskSeerCore
import SwiftUI

@main
struct DiskSeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("DiskSeer", id: "main") {
            ContentView()
                .environment(model)
                .task {
                    AppDelegate.model = model
                    Automation.runIfRequested(model: model)
                }
        }
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Home Folder") { model.startScan(path: ScanLocation.home) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Scan Entire Disk") { model.startScan(path: ScanLocation.entireDisk) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Scan Folder…") { Workspace.chooseFolder().map(model.startScan) }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Go") {
                ForEach(Array(AppModel.Section.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                        .disabled(model.root == nil)
                }
                Divider()
                Button("Zoom In") { if let s = model.selection { model.zoom(into: s) } }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(model.selection?.isContainer != true)
                Button("Enclosing Folder") { model.zoomOut() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.zoomRoot == nil)
            }
        }

        .commands {
            CommandMenu("Item") {
                Button("Quick Look") { if let s = model.selection { Workspace.quickLook(s.path) } }
                    .keyboardShortcut("y", modifiers: .command)
                Button("Reveal in Finder") { if let s = model.selection { Workspace.reveal(s.path) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Copy Path") { if let s = model.selection { Workspace.copyPath(s.path) } }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Divider()
                Button("Move to Trash…") { if let s = model.selection { model.requestTrash([s]) } }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.startupDiskIsLow ? "exclamationmark.triangle.fill" : "internaldrive")
                Text(ByteFormat.string(model.startupFreeSpace))
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?

    /// Folders dropped on the Dock icon or opened with "Open With › DiskSeer".
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in AppDelegate.model?.startScan(path: url.path) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` gives us a plain process: make it a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Free-space glance in the menu bar.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var volumes: [VolumeInfo] = VolumeInfo.mounted()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DiskSeer").font(.headline)
                Spacer()
                Button { volumes = VolumeInfo.mounted() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            ForEach(volumes) { volume in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                        Text(volume.name).font(.callout.weight(.medium))
                        Spacer()
                        Text("\(ByteFormat.string(volume.availableCapacity)) free").font(.callout.monospacedDigit())
                    }
                    ProportionBar(fraction: volume.usedFraction, color: volume.usedFraction > 0.9 ? .red : .accentColor)
                    if volume.purgeable > 0 {
                        Text("+ \(ByteFormat.string(volume.purgeable)) purgeable").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.root != nil {
                Divider()
                Text("Last scan: \(ByteFormat.string(model.reclaimableSafe)) safe to clean").font(.callout)
            }
            Divider()
            HStack {
                Button("Open DiskSeer") { openWindow(id: "main"); NSApp.activate() }
                Spacer()
                Button("Quick Scan Home") {
                    openWindow(id: "main")
                    NSApp.activate()
                    model.startScan(path: ScanLocation.home)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Privacy & Safety") {
                LabeledContent("Full Disk Access", value: model.hasFullDiskAccess ? "Granted" : "Not granted")
                Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                Text("DiskSeer only reads metadata while scanning. File contents are read only when you look for duplicates. Removal always goes through the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored in Smart Clean") {
                if model.ignoredPaths.isEmpty && model.ignoredGroups.isEmpty {
                    Text("Nothing ignored. Right-click a finding to ignore it.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.ignoredGroups).sorted(), id: \.self) { id in
                    HStack {
                        Label(id, systemImage: "rectangle.stack")
                        Spacer()
                        Button("Restore") { model.ignoredGroups.remove(id) }
                    }
                }
                ForEach(Array(model.ignoredPaths).sorted(), id: \.self) { path in
                    HStack {
                        Label(path.abbreviatingHome, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Restore") { model.ignoredPaths.remove(path) }
                    }
                }
            }
            Section("Apple Intelligence") {
                LabeledContent("Status", value: AppleIntelligence.isAvailable ? "Available on this Mac" : AppleIntelligence.unavailableReason)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
