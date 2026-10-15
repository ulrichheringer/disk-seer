import DiskSeerCore
import SwiftUI

/// Category-level view of the disk produced by the classifier.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedKey: String? = "unknown"
    private var selectedCategory: FileCategory? { selectedKey.flatMap(FileCategory.init(rawValue:)) }
    @State private var topItems: [FileNode] = []
    @State private var unknown: [FileNode] = []

    var body: some View {
        HSplitView {
            categoryList.frame(minWidth: 330, idealWidth: 380, maxWidth: 480)
            detail.frame(minWidth: 380, maxWidth: .infinity)
        }
        .task(id: TaskKey(category: selectedCategory, version: model.treeVersion)) { await load() }
    }

    struct TaskKey: Equatable { var category: FileCategory?; var version: Int }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Insights").font(.title2.weight(.semibold))
                Text("Every item was classified by location, name, context and contents, with a predictive model for the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            List(selection: $selectedKey) {
                Label("Unrecognised items", systemImage: "questionmark.folder")
                    .tag("unknown")
                Section("Categories") {
                    let maxSize = model.categoryTotals.first?.size ?? 1
                    ForEach(model.categoryTotals, id: \.category) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: item.category.symbol).foregroundStyle(item.category.color).frame(width: 18)
                                Text(item.category.displayName)
                                Spacer()
                                Text(ByteFormat.string(item.size)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            ProportionBar(fraction: Double(item.size) / Double(max(maxSize, 1)), color: item.category.color)
                                .padding(.leading, 26)
                        }
                        .padding(.vertical, 2)
                        .tag(item.category.rawValue)
                    }
                }
            }
            .listStyle(.sidebar)
            modelStats.padding(12)
        }
    }

    private var modelStats: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain").foregroundStyle(.secondary)
            Text("Predictive model: \(model.classifier.model.trainingDocumentCount.formatted()) training examples (self-trained on this Mac), \(model.classifier.model.vocabularySize.formatted()) words")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: AppleIntelligence.isAvailable ? "apple.intelligence" : "circle.slash").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detail: some View {
        let nodes = selectedCategory == nil ? unknown : topItems
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let c = selectedCategory {
                    Image(systemName: c.symbol).foregroundStyle(c.color).font(.title2)
                    Text(c.displayName).font(.title3.weight(.semibold))
                } else {
                    Image(systemName: "questionmark.folder").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Unrecognised items").font(.title3.weight(.semibold))
                        Text("Large items DiskSeer could not identify. Select one and ask for an explanation.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(16)
            if nodes.isEmpty {
                EmptyStateView(symbol: "checkmark.seal", title: selectedCategory == nil ? "Everything large was recognised" : "Nothing here",
                               message: selectedCategory == nil ? "No unidentified item above 5 MB." : "No items of this kind above 1 MB.")
            } else {
            List(nodes, id: \.id, selection: Binding(get: { model.selection?.id }, set: { id in
                model.selection = nodes.first { $0.id == id }
            })) { node in
                HStack(spacing: 8) {
                    NodeIcon(node: node, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).lineLimit(1)
                        Text(ScanLocation.displayPath(node.parent?.path ?? "").abbreviatingHome)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    SizeText(bytes: node.size)
                }
                .tag(node.id)
                .contextMenu {
                    Button("Show in Explorer") { model.reveal(node) }
                    Button("Reveal in Finder") { Workspace.reveal(node.path) }
                }
            }
            }
        }
    }

    private func load() async {
        guard let root = model.root else { return }
        let category = selectedCategory
        let result = await Task.detached(priority: .userInitiated) { () -> [FileNode] in
            var items: [FileNode] = []
            // Top-most nodes of the category (don't list children of an already listed folder).
            root.walk { node in
                if node === root { return true }
                if let category {
                    if node.category == category && node.size > 1_000_000 {
                        items.append(node)
                        return false
                    }
                } else if node.category == .other && node.size > 5_000_000 {
                    items.append(node)
                    return false
                }
                return node.isContainer && node.size > 1_000_000
            }
            return Array(items.sorted { $0.size > $1.size }.prefix(200))
        }.value
        if category == nil { unknown = result } else { topItems = result }
    }
}
