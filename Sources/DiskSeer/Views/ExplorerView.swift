import DiskSeerCore
import SwiftUI

struct ExplorerView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\RowItem.size, order: .reverse)]
    @State private var tableSelection: Set<ObjectIdentifier> = []

    var body: some View {
        @Bindable var model = model
        if let root = model.root {
            let current = model.zoomRoot ?? root
            VStack(spacing: 0) {
                ExplorerToolbar(current: current)
                Divider()
                HSplitView {
                    Group {
                        if model.visualization == .blocks {
                            TreemapView(
                                root: current,
                                version: model.treeVersion,
                                extraBlocks: model.extraBlocks,
                                colorMode: model.colorMode,
                                maxDepth: Int(model.treemapDepth),
                                selection: $model.selection,
                                onZoom: { model.zoom(into: $0) },
                                onTrash: { model.requestTrash([$0]) }
                            )
                        } else {
                            SunburstView(
                                root: current,
                                version: model.treeVersion,
                                colorMode: model.colorMode,
                                maxDepth: min(Int(model.treemapDepth), 7),
                                selection: $model.selection,
                                onZoom: { model.zoom(into: $0) },
                                onZoomOut: { model.zoomOut() },
                                onTrash: { model.requestTrash([$0]) }
                            )
                        }
                    }
                    .padding(6)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Group {
                        if model.explorerSearch.isEmpty {
                            childList(for: current)
                        } else {
                            SearchResultsList(root: current, query: model.explorerSearch)
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
                }
                if model.colorMode == .category {
                    CategoryLegend(current: current).padding(.horizontal, 10).padding(.vertical, 6)
                } else if model.colorMode == .age {
                    AgeLegend().padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
        } else {
            EmptyStateView(symbol: "square.grid.3x3", title: "No scan yet", message: "Scan a disk or folder to explore it.")
        }
    }

    struct RowItem: Identifiable {
        let node: FileNode
        var id: ObjectIdentifier { node.id }
        var name: String { node.name }
        var size: Int64 { node.size }
        var files: Int { node.fileCount }
        var modified: TimeInterval { node.newestModified }
        var category: String { node.category.displayName }
    }

    private func childList(for current: FileNode) -> some View {
        let rows = current.children.filter { $0.size > 0 || $0.kind != .file }.map(RowItem.init).sorted(using: sortOrder)
        let total = max(current.size, 1)
        return Table(rows, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    NodeIcon(node: row.node, size: 16)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    if row.node.isRestricted {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("DiskSeer could not read this folder")
                    }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Size", value: \.size) { row in
                VStack(alignment: .trailing, spacing: 2) {
                    SizeText(bytes: row.size).font(.callout)
                    ProportionBar(fraction: Double(row.size) / Double(total), color: row.node.category.color)
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Kind", value: \.category) { row in
                CategoryChip(category: row.node.category, compact: true)
            }
            .width(34)
            TableColumn("Modified", value: \.modified) { row in
                Text(AgeFormat.short(row.modified)).foregroundStyle(.secondary).font(.callout)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
            let nodes = current.children.filter { ids.contains($0.id) }
            if nodes.count == 1, let node = nodes.first {
                if node.isContainer { Button("Zoom In") { model.zoom(into: node) } }
                Button("Reveal in Finder") { Workspace.reveal(node.path) }
                Button("Quick Look") { Workspace.quickLook(node.path) }
                Button("Copy Path") { Workspace.copyPath(node.path) }
                Divider()
            }
            if !nodes.isEmpty {
                Button("Move to Trash…", role: .destructive) { model.requestTrash(nodes) }
            }
        } primaryAction: { ids in
            if let node = current.children.first(where: { ids.contains($0.id) }), node.isContainer {
                model.zoom(into: node)
            }
        }
        .onChange(of: tableSelection) { _, ids in
            if let id = ids.first, ids.count == 1, let node = current.children.first(where: { $0.id == id }) {
                if model.selection !== node { model.selection = node }
            }
        }
        .onChange(of: model.selection) { _, node in
            if let node, node.parent === current { tableSelection = [node.id] } else if node == nil { tableSelection = [] }
        }
    }
}

private struct ExplorerToolbar: View {
    @Environment(AppModel.self) private var model
    let current: FileNode

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Button { model.zoomOut() } label: { Image(systemName: "chevron.left") }
                .disabled(model.zoomRoot == nil)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Up one level (⌘↑)")
            Breadcrumbs(current: current)
            Spacer()
            TextField("Find in \(current.parent == nil ? "scan" : current.name)", text: $model.explorerSearch)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
            Picker("View", selection: $model.visualization) {
                ForEach(AppModel.Visualization.allCases) { Image(systemName: $0.symbol).help($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Blocks (treemap) or Rings (sunburst)")
            Picker("Color", selection: $model.colorMode) {
                ForEach(AppModel.ColorMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .help("Color blocks by kind, by age (last change) or by top-level folder")
            HStack(spacing: 4) {
                Image(systemName: "square.3.layers.3d").foregroundStyle(.secondary)
                Slider(value: $model.treemapDepth, in: 1...10, step: 1).frame(width: 90)
            }
            .help("Nesting depth: \(Int(model.treemapDepth)) levels")
            Toggle(isOn: $model.showFreeSpace) { Image(systemName: "circle.dashed") }
                .toggleStyle(.button)
                .help("Show free space and space outside the scanned folder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model
    let current: FileNode

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(current.ancestry.enumerated()), id: \.element.id) { index, node in
                    if index > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                    Button {
                        model.zoom(into: node)
                    } label: {
                        HStack(spacing: 4) {
                            if index == 0 { Image(systemName: model.isEntireDisk ? "internaldrive" : "folder") }
                            Text(index == 0 ? model.displayName : node.name).lineLimit(1)
                            if node === current { Text(ByteFormat.string(node.size)).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .font(.callout.weight(node === current ? .semibold : .regular))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(node === current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct CategoryLegend: View {
    let current: FileNode

    var body: some View {
        let totals = categoryTotals()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(totals.prefix(12), id: \.0) { category, size in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(category.color).frame(width: 10, height: 10)
                        Text(category.displayName).font(.caption)
                        Text(ByteFormat.string(size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private func categoryTotals() -> [(FileCategory, Int64)] {
        var totals: [FileCategory: Int64] = [:]
        // Fast approximation: by category of direct children and grandchildren.
        for child in current.children {
            if child.isContainer && child.children.count > 0 && child.size > current.size / 20 {
                for grand in child.children { totals[grand.category, default: 0] += grand.size }
            } else {
                totals[child.category, default: 0] += child.size
            }
        }
        return totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }
    }
}

private struct AgeLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Last change:").font(.caption).foregroundStyle(.secondary)
            ForEach(AgePalette.legend, id: \.0) { label, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    Text(label).font(.caption)
                }
            }
            Spacer()
        }
    }
}

/// Items anywhere below the current folder whose name matches the query.
private struct SearchResultsList: View {
    @Environment(AppModel.self) private var model
    let root: FileNode
    let query: String
    @State private var results: [FileNode] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(searching ? "Searching…" : "\(results.count) matches").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(results.reduce(0) { $0 + $1.size })).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            List(results, id: \.id, selection: Binding(get: { model.selection?.id }, set: { id in
                model.selection = results.first { $0.id == id }
            })) { node in
                HStack(spacing: 6) {
                    NodeIcon(node: node, size: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).lineLimit(1)
                        Text(ScanLocation.displayPath(node.parent?.path ?? "").abbreviatingHome)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    SizeText(bytes: node.size).font(.callout)
                }
                .tag(node.id)
                .contextMenu {
                    Button("Show in Explorer") { model.reveal(node) }
                    Button("Reveal in Finder") { Workspace.reveal(node.path) }
                    Button("Move to Trash…", role: .destructive) { model.requestTrash([node]) }
                }
            }
        }
        .task(id: query + "\(model.treeVersion)") {
            searching = true
            let q = query.lowercased()
            let base = root
            try? await Task.sleep(for: .milliseconds(200)) // debounce typing
            if Task.isCancelled { return }
            results = await Task.detached(priority: .userInitiated) {
                var heap = TopK<FileNode>(capacity: 300) { $0.size < $1.size }
                base.walk { node in
                    if node !== base && node.name.lowercased().contains(q) {
                        heap.insert(node)
                        return false // report the top-most match, not everything inside it
                    }
                    return node.isContainer
                }
                return heap.sortedDescending()
            }.value
            searching = false
        }
    }
}
