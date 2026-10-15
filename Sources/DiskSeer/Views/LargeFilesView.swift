import DiskSeerCore
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var minimumSizeMB = 100.0
    @State private var age: AgeFilter = .any
    @State private var category: FileCategory?
    @State private var search = ""
    @State private var includeFolders = false
    @State private var selection: Set<ObjectIdentifier> = []
    @State private var sortOrder = [KeyPathComparator(\Row.size, order: .reverse)]
    @State private var rows: [Row] = []

    enum AgeFilter: String, CaseIterable, Identifiable {
        case any = "Any age", month = "Unused > 1 month", quarter = "Unused > 3 months", year = "Unused > 1 year", twoYears = "Unused > 2 years"
        var id: String { rawValue }
        var days: Double {
            switch self {
            case .any: 0
            case .month: 30
            case .quarter: 90
            case .year: 365
            case .twoYears: 730
            }
        }
    }

    struct Row: Identifiable {
        let node: FileNode
        var id: ObjectIdentifier { node.id }
        var name: String { node.name }
        var size: Int64 { node.size }
        var lastUsed: TimeInterval { max(node.newestModified, node.accessed) }
        var category: String { node.category.displayName }
        var path: String { ScanLocation.displayPath(node.parent?.path ?? "").abbreviatingHome }
    }

    private struct FilterKey: Equatable {
        var size: Double, age: AgeFilter, category: FileCategory?, search: String, folders: Bool, version: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 6) {
                        NodeIcon(node: row.node, size: 18)
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Size", value: \.size) { row in SizeText(bytes: row.size) }.width(min: 70, ideal: 85)
                TableColumn("Kind", value: \.category) { row in CategoryChip(category: row.node.category) }.width(min: 90, ideal: 150)
                TableColumn("Last used", value: \.lastUsed) { row in
                    Text(AgeFormat.relative(row.lastUsed)).foregroundStyle(AgeFormat.days(since: row.lastUsed) > 365 ? .orange : .secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Location", value: \.path) { row in
                    Text(row.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .onChange(of: sortOrder) { _, order in rows.sort(using: order) }
            .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
                let nodes = rows.filter { ids.contains($0.id) }.map(\.node)
                if nodes.count == 1, let node = nodes.first {
                    Button("Reveal in Finder") { Workspace.reveal(node.path) }
                    Button("Quick Look") { Workspace.quickLook(node.path) }
                    Button("Show in Explorer") { model.reveal(node) }
                    Button("Copy Path") { Workspace.copyPath(node.path) }
                    Divider()
                }
                if !nodes.isEmpty { Button("Move to Trash…", role: .destructive) { model.requestTrash(nodes) } }
            } primaryAction: { ids in
                if let node = rows.first(where: { ids.contains($0.id) })?.node { Workspace.quickLook(node.path) }
            }
            footer
        }
        .task(id: FilterKey(size: minimumSizeMB, age: age, category: category, search: search, folders: includeFolders, version: model.treeVersion)) {
            await recompute()
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Large & Old Files").font(.title2.weight(.semibold)).fixedSize()
                Text("Find big items you no longer use").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            HStack(spacing: 12) {
                Text("Larger than").font(.callout).fixedSize()
                Slider(value: $minimumSizeMB, in: 10...5000).frame(minWidth: 90, maxWidth: 160)
                Text(ByteFormat.string(Int64(minimumSizeMB * 1_000_000))).monospacedDigit().fixedSize()
                Picker("Age", selection: $age) { ForEach(AgeFilter.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden()
                    .fixedSize()
                Picker("Kind", selection: $category) {
                    Text("All kinds").tag(FileCategory?.none)
                    Divider()
                    ForEach(FileCategory.allCases) { c in
                        Label(c.displayName, systemImage: c.symbol).tag(Optional(c))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Toggle("Include folders", isOn: $includeFolders)
                    .fixedSize()
                    .help("Also list folders not changed for the chosen time")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        let selectedRows = rows.filter { selection.contains($0.id) }
        let selectedSize = selectedRows.reduce(0) { $0 + $1.size }
        return HStack {
            Text("\(rows.count) items · \(ByteFormat.string(rows.reduce(0) { $0 + $1.size }))").foregroundStyle(.secondary)
            Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderless)
            Spacer()
            if !selectedRows.isEmpty {
                Text("\(selectedRows.count) selected · \(ByteFormat.string(selectedSize))")
                Button("Reveal") { selectedRows.prefix(10).forEach { Workspace.reveal($0.node.path) } }
                Button(role: .destructive) { model.requestTrash(selectedRows.map(\.node)) } label: { Label("Move to Trash…", systemImage: "trash") }
            }
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func exportCSV() {
        var table = [["Name", "Path", "Size (bytes)", "Size", "Kind", "Last used"]]
        for row in rows {
            table.append([row.name, ScanLocation.canonicalPath(row.node.path), "\(row.size)", ByteFormat.string(row.size),
                          row.category, Date(timeIntervalSince1970: row.lastUsed).formatted(date: .numeric, time: .omitted)])
        }
        CSVExport.save(rows: table, suggestedName: "DiskSeer Large Files.csv")
    }

    private func recompute() async {
        guard let root = model.root else { rows = []; return }
        let minimum = Int64(minimumSizeMB * 1_000_000)
        let days = age.days
        let category = self.category
        let query = search.lowercased()
        let folders = includeFolders
        let order = sortOrder
        let result = await Task.detached(priority: .userInitiated) { () -> [Row] in
            var candidates: [FileNode] = root.largestFiles(limit: 2000, minimumSize: minimum)
            if folders {
                var dirs: [FileNode] = []
                root.walk { node in
                    if node.kind == .directory && node.size >= minimum && node !== root && days > 0
                        && AgeFormat.days(since: node.newestModified) >= days {
                        dirs.append(node)
                        return false
                    }
                    return node.isContainer && node.size >= minimum
                }
                candidates += dirs
            }
            let now = Date()
            return candidates.filter { node in
                if days > 0 && AgeFormat.days(since: max(node.newestModified, node.accessed), now: now) < days { return false }
                if let category, node.category != category { return false }
                if !query.isEmpty && !node.name.lowercased().contains(query) && !node.path.lowercased().contains(query) { return false }
                return true
            }
            .map(Row.init)
            .sorted(using: order)
        }.value
        rows = result
        selection = selection.filter { id in result.contains { $0.id == id } }
    }
}
