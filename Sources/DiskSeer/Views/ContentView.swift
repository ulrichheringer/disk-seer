import DiskSeerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .idle:
                WelcomeView()
            case .scanning:
                ScanProgressView()
            case let .failed(message):
                VStack(spacing: 14) {
                    EmptyStateView(symbol: "exclamationmark.triangle", title: "Scan failed", message: message)
                    Button("Back") { model.phase = .idle }
                }
            case .ready:
                mainInterface
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .overlay(alignment: .bottom) { toast }
        .sheet(item: $model.pendingTrash) { request in TrashConfirmationSheet(request: request) }
        .sheet(item: $model.pendingCommand) { request in CommandConfirmationSheet(request: request) }
        .sheet(item: $model.commandResult) { result in CommandResultSheet(result: result) }
    }

    private var mainInterface: some View {
        @Bindable var model = model
        return NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
                .inspector(isPresented: $model.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.phase = .idle } label: { Label("Locations", systemImage: "house") }
                    .help("Choose another disk or folder")
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Scan again (⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .navigationTitle(model.displayName)
        .navigationSubtitle(model.root.map { "\(ByteFormat.string($0.size)) scanned" } ?? "")
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .overview: OverviewView()
        case .explorer: ExplorerView()
        case .insights: InsightsView()
        case .smartClean: SmartCleanView()
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .apps: AppsView()
        case .virtualization: VirtualizationView()
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let command = model.runningCommand {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Running \(command)…").font(.system(.callout, design: .monospaced)).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 18)
        } else if let message = model.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).lineLimit(3)
                if model.trashSize > 0 && message.contains("Trash") && !message.contains("emptied") {
                    Text("Empty the Trash to free the space.").foregroundStyle(.secondary)
                }
                Button { model.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.section) {
            Section("Disk") {
                row(.overview)
                row(.explorer)
                row(.insights)
            }
            Section("Clean Up") {
                row(.smartClean, badge: model.reclaimableSafe)
                row(.largeFiles)
                row(.duplicates, badge: model.duplicates.reduce(0) { $0 + $1.wastedBytes })
                row(.apps)
                row(.virtualization, badge: model.virtualDisks.reduce(0) { $0 + $1.allocated })
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { diskSummary }
    }

    private func row(_ section: AppModel.Section, badge: Int64 = 0) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(badge > 0 ? Text(ByteFormat.string(badge)).monospacedDigit() : nil)
            .tag(section)
    }

    @ViewBuilder
    private var diskSummary: some View {
        if let volume = model.volume {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "internaldrive")
                    Text(volume.name).font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(ByteFormat.string(volume.availableCapacity)) free").font(.caption.monospacedDigit())
                }
                ProportionBar(fraction: volume.usedFraction, color: volume.usedFraction > 0.9 ? .red : .accentColor)
            }
            .padding(12)
        }
    }
}

// MARK: - Confirmation sheets

struct TrashConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.TrashRequest

    var body: some View {
        let policy = SafetyPolicy()
        let verdicts = request.items.map { ($0, policy.verdict(forPath: $0.path)) }
        let blocked = verdicts.filter { !$0.1.isAllowed }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill").font(.system(size: 40)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(request.title) to the Trash?").font(.headline)
                    Text("\(request.items.count) item\(request.items.count == 1 ? "" : "s") · \(ByteFormat.string(request.totalSize)). You can restore them from the Trash until you empty it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            List {
                ForEach(Array(verdicts.prefix(200).enumerated()), id: \.offset) { _, entry in
                    HStack {
                        FileIcon(path: entry.0.path, size: 16)
                        Text(ScanLocation.displayPath(entry.0.path).abbreviatingHome).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let reason = entry.1.reason {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).help(reason)
                        }
                        Text(ByteFormat.string(entry.0.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 280)
            if !blocked.isEmpty {
                Label("\(blocked.count) protected item\(blocked.count == 1 ? "" : "s") will be skipped.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingTrash = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { model.performTrash(request); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocked.count == request.items.count)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct CommandConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.CommandRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run cleanup command?").font(.headline)
                    Text(request.title).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(request.command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            Text("The command runs with your user account, exactly like typing it in Terminal. Output is shown when it finishes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy Command") { Workspace.copy(request.command) }
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingCommand = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { model.run(request); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct CommandResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let result: AppModel.CommandResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(result.output.succeeded ? "Command finished" : "Command failed (exit \(result.output.status))",
                  systemImage: result.output.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(result.output.succeeded ? .green : .red)
            Text(result.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            ScrollView {
                Text((result.output.stdout + (result.output.stderr.isEmpty ? "" : "\n" + result.output.stderr)).trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
            .padding(8)
            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("Rescan to see the updated sizes.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
