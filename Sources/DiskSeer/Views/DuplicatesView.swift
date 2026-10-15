import DiskSeerCore
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var marked: Set<ObjectIdentifier> = []
    @State private var expanded: Set<String> = []

    private var wasted: Int64 { model.duplicates.reduce(0) { $0 + $1.wastedBytes } }
    private var markedSize: Int64 {
        model.duplicates.flatMap(\.files).filter { marked.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicates").font(.title2.weight(.semibold))
                    Text(model.duplicateState == .done
                         ? "\(model.duplicates.count) sets of identical files · \(ByteFormat.string(wasted)) wasted"
                         : "Finds files with identical content (SHA-256), not just the same name.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Scope", selection: $model.duplicateScope) {
                    Text("My files").tag(DuplicateFinder.Scope.personal)
                    Text("Everything").tag(DuplicateFinder.Scope.everything)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("“My files” skips app data, caches, developer tools and project dependencies, where duplicates are expected")
                Picker("Minimum size", selection: $model.duplicateMinimumSize) {
                    Text("100 KB").tag(Int64(100_000))
                    Text("1 MB").tag(Int64(1_000_000))
                    Text("10 MB").tag(Int64(10_000_000))
                    Text("100 MB").tag(Int64(100_000_000))
                }
                .frame(width: 190)
                if model.duplicateState == .running {
                    ProgressView(value: Double(model.duplicateProgress.hashed), total: Double(max(model.duplicateProgress.total, 1)))
                        .frame(width: 120)
                    Button("Stop") { model.cancelDuplicates() }
                } else {
                    Button(model.duplicateState == .done ? "Search Again" : "Find Duplicates") {
                        marked.removeAll()
                        model.findDuplicates()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.root == nil)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()

            switch model.duplicateState {
            case .idle:
                EmptyStateView(symbol: "doc.on.doc", title: "Look for duplicate files",
                               message: "DiskSeer compares sizes first, then partial and full SHA-256 hashes, so only truly identical files are reported.")
            case .running:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Comparing \(model.duplicateProgress.hashed.formatted()) of \(model.duplicateProgress.total.formatted()) candidate files…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done where model.duplicates.isEmpty:
                EmptyStateView(symbol: "checkmark.seal", title: "No duplicates", message: "No identical files above the minimum size were found.")
            case .done:
                List {
                    ForEach(model.duplicates) { group in
                        groupView(group)
                    }
                }
                .listStyle(.inset)
                HStack {
                    Button("Mark all copies except the original") { markAllButOriginal() }
                    Button("Clear marks") { marked.removeAll() }
                    Spacer()
                    Text("\(marked.count) marked · \(ByteFormat.string(markedSize))").foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        let nodes = model.duplicates.flatMap(\.files).filter { marked.contains($0.id) }
                        model.requestTrash(nodes, title: "\(nodes.count) duplicate files")
                        marked.removeAll()
                    } label: { Label("Move Marked to Trash…", systemImage: "trash") }
                        .disabled(marked.isEmpty)
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
            }
        }
    }

    private func markAllButOriginal() {
        for group in model.duplicates {
            let original = group.suggestedOriginal
            for file in group.files where file !== original { marked.insert(file.id) }
        }
    }

    private func groupView(_ group: DuplicateGroup) -> some View {
        let binding = Binding(get: { expanded.contains(group.id) }, set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } })
        return DisclosureGroup(isExpanded: binding) {
            ForEach(group.files, id: \.id) { file in
                let isOriginal = file === group.suggestedOriginal
                HStack(spacing: 8) {
                    Button {
                        if marked.contains(file.id) { marked.remove(file.id) } else { marked.insert(file.id) }
                    } label: {
                        Image(systemName: marked.contains(file.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(marked.contains(file.id) ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    Text(ScanLocation.displayPath(file.path).abbreviatingHome).lineLimit(1).truncationMode(.middle)
                    if isOriginal {
                        Text("suggested original").font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                    }
                    Spacer()
                    Text(AgeFormat.relative(file.modified)).font(.caption).foregroundStyle(.secondary)
                    Button { Workspace.reveal(file.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                }
                .padding(.leading, 24)
            }
        } label: {
            HStack(spacing: 10) {
                FileIcon(path: group.files[0].path, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.files[0].name).font(.body.weight(.medium)).lineLimit(1)
                    Text("\(group.files.count) copies · \(ByteFormat.string(group.fileSize)) each").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteFormat.string(group.wastedBytes) + " wasted").monospacedDigit()
            }
            .padding(.vertical, 3)
        }
    }
}
