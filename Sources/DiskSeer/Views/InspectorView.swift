import DiskSeerCore
import SwiftUI

/// Details, AI explanation and actions for the selected item.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let node = model.selection ?? model.zoomRoot ?? model.root {
            NodeInspector(node: node)
                .id(node.id)
        } else {
            EmptyStateView(symbol: "sidebar.right", title: "Nothing selected", message: "Select a block or a row to see what it is.")
        }
    }
}

private struct NodeInspector: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    @State private var classification: Classification?
    @State private var aiAnswer: String?
    @State private var aiError: String?
    @State private var aiLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let classification { whatIsThis(classification) }
                if let advice = classification?.advice { adviceCard(advice) }
                appleIntelligenceCard
                details
                actions
            }
            .padding(14)
        }
        .task(id: node.id) {
            let classifier = model.classifier
            let target = node
            classification = await Task.detached { classifier.explain(target) }.value
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            NodeIcon(node: node, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.parent == nil ? model.displayName : node.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(ByteFormat.string(node.size))
                    .font(.title2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(node.category.color)
                if let root = model.root, node !== root {
                    Text("\(ByteFormat.percent(node.size, of: root.size)) of scanned space")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func whatIsThis(_ c: Classification) -> some View {
        Card(title: "What is this?", symbol: "sparkles") {
            HStack {
                CategoryChip(category: c.category)
                Spacer()
                Text(c.source.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Text(c.label).font(.body.weight(.semibold))
            Text(c.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Confidence").font(.caption).foregroundStyle(.secondary)
                ProportionBar(fraction: c.confidence, color: c.confidence > 0.75 ? .green : (c.confidence > 0.5 ? .orange : .red))
                Text("\(Int(c.confidence * 100))%").font(.caption.monospacedDigit())
            }
            if !c.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(c.evidence, id: \.self) { line in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "checkmark.circle").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                            Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func adviceCard(_ advice: CleanupAdvice) -> some View {
        Card(title: "Can I delete it?", symbol: "trash") {
            SafetyBadge(safety: advice.safety)
            Text(advice.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            if advice.regenerable {
                Label("Recreated automatically when needed", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let command = advice.command {
                HStack {
                    Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(6).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                    Button { Workspace.copy(command) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy command")
                    Button("Run…") { model.pendingCommand = .init(command: command, title: classification?.label ?? command) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var appleIntelligenceCard: some View {
        Card(title: "Ask Apple Intelligence", symbol: "apple.intelligence") {
            if let aiAnswer {
                Text(AppleIntelligence.markdown(aiAnswer)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if let aiError {
                Text(aiError).font(.caption).foregroundStyle(.secondary)
            } else if !AppleIntelligence.isAvailable {
                Text(AppleIntelligence.unavailableReason).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Get an on-device second opinion about this item. Nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if AppleIntelligence.isAvailable && aiAnswer == nil {
                Button {
                    ask()
                } label: {
                    if aiLoading { ProgressView().controlSize(.small) } else { Label("Explain this item", systemImage: "sparkles") }
                }
                .disabled(aiLoading || classification == nil || node.isSynthetic)
            }
        }
    }

    private func ask() {
        guard let classification else { return }
        aiLoading = true
        aiError = nil
        let target = node
        Task {
            do {
                aiAnswer = try await AppleIntelligence.explain(target, local: classification)
            } catch {
                aiError = error.localizedDescription
            }
            aiLoading = false
        }
    }

    private var details: some View {
        Card(title: "Details", symbol: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                row("Location", ScanLocation.displayPath(node.path).abbreviatingHome)
                row("On disk", ByteFormat.string(node.size))
                if node.logicalSize != node.size { row("Logical size", ByteFormat.string(node.logicalSize)) }
                if node.isContainer {
                    row("Files", node.fileCount.formatted())
                    row("Items inside", node.children.count.formatted())
                }
                row("Modified", AgeFormat.relative(node.modified))
                if node.isContainer { row("Latest change inside", AgeFormat.relative(node.newestModified)) }
                if node.accessed > 0 { row("Last opened", AgeFormat.relative(node.accessed)) }
                if node.isRestricted { row("Access", "Restricted — grant Full Disk Access") }
                if node.isHardLinkDuplicate { row("Hard link", "Counted once elsewhere") }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled).lineLimit(3)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !node.isSynthetic {
            let verdict = model.verdict(for: node)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { Workspace.reveal(node.path) } label: { Label("Reveal", systemImage: "folder") }
                    Button { Workspace.quickLook(node.path) } label: { Label("Quick Look", systemImage: "eye") }
                    Button { Workspace.copyPath(node.path) } label: { Image(systemName: "doc.on.clipboard") }.help("Copy path")
                    Button { Workspace.openInTerminal(node.path) } label: { Image(systemName: "terminal") }.help("Open in Terminal")
                }
                HStack {
                    if node.isContainer && node !== (model.zoomRoot ?? model.root) {
                        Button { model.zoom(into: node) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    }
                    Button(role: .destructive) { model.requestTrash([node]) } label: {
                        Label("Move to Trash…", systemImage: "trash")
                    }
                    .disabled(!verdict.isAllowed)
                }
                if let reason = verdict.reason {
                    Label(reason, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
            }
            .controlSize(.regular)
        }
    }
}
