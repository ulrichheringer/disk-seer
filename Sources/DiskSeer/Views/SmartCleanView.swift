import DiskSeerCore
import SwiftUI

struct SmartCleanView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var safetyFilter: SafetyFilter = .all
    @State private var search = ""

    enum SafetyFilter: String, CaseIterable, Identifiable {
        case all = "All", safe = "Safe", review = "Review", caution = "Caution"
        var id: String { rawValue }
    }

    private var visibleSections: [FindingSection] {
        model.visibleFindingSections.compactMap { section in
            var findings = section.findings
            switch safetyFilter {
            case .all: break
            case .safe: findings = findings.filter { $0.safety == .safe }
            case .review: findings = findings.filter { $0.safety == .review }
            case .caution: findings = findings.filter { $0.safety >= .caution }
            }
            if !search.isEmpty {
                let q = search.lowercased()
                findings = findings.filter {
                    $0.title.lowercased().contains(q) || $0.path.lowercased().contains(q) || section.group.title.lowercased().contains(q)
                }
            }
            return findings.isEmpty ? nil : FindingSection(group: section.group, findings: findings)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.findingSections.isEmpty {
                EmptyStateView(symbol: "sparkles", title: "Nothing to clean", message: "No caches, build folders or leftovers worth removing were found.")
            } else {
                List {
                    ForEach(visibleSections) { section in
                        sectionView(section)
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter findings")
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Clean").font(.title2.weight(.semibold))
                Text("\(ByteFormat.string(model.reclaimableSafe)) can be removed safely · \(ByteFormat.string(model.reclaimableReview)) more to review")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Show", selection: $safetyFilter) {
                ForEach(SafetyFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Menu {
                Button("Select All Safe Items") { selectAll { $0.safety == .safe } }
                Button("Select Everything Visible") { selectAll { _ in true } }
                Button("Deselect All") { model.selectedFindings.removeAll() }
            } label: {
                Image(systemName: "checklist")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { exportCSV() } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export findings as CSV")
            Button {
                model.requestTrashSelectedFindings()
            } label: {
                Label("Move \(ByteFormat.string(model.selectedFindingSize)) to Trash", systemImage: "trash")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(model.selectedFindings.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func exportCSV() {
        var rows = [["Group", "Item", "Path", "Size (bytes)", "Size", "Safety", "Detail"]]
        for section in visibleSections {
            for f in section.findings {
                rows.append([section.group.title, f.title, ScanLocation.canonicalPath(f.path), "\(f.size)", ByteFormat.string(f.size), f.safety.title, f.detail])
            }
        }
        CSVExport.save(rows: rows, suggestedName: "DiskSeer Smart Clean.csv")
    }

    private func selectAll(_ predicate: (CleanupFinding) -> Bool) {
        for section in visibleSections {
            for finding in section.findings where predicate(finding) && finding.group.id != "sys.trash" {
                model.selectedFindings.insert(finding.id)
            }
        }
    }

    private func checkboxState(_ section: FindingSection) -> TriStateCheckbox.State {
        let selected = section.findings.filter { model.selectedFindings.contains($0.id) }.count
        if selected == 0 { return .off }
        return selected == section.findings.count ? .on : .mixed
    }

    @ViewBuilder
    private func sectionView(_ section: FindingSection) -> some View {
        let isTrash = section.group.id == "sys.trash"
        let isExpanded = Binding(
            get: { expanded.contains(section.id) || !search.isEmpty },
            set: { if $0 { expanded.insert(section.id) } else { expanded.remove(section.id) } }
        )
        DisclosureGroup(isExpanded: isExpanded) {
            if isTrash {
                HStack {
                    Text("Items in the Trash are already deleted from their folders but still occupy space. Emptying the Trash is permanent.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Empty Trash…") { confirmEmptyTrash = true }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(section.findings) { finding in
                    FindingRow(finding: finding)
                }
            }
        } label: {
            HStack(spacing: 10) {
                if !isTrash {
                    TriStateCheckbox(state: checkboxState(section)) { toggle(section) }
                } else {
                    Image(systemName: "trash").frame(width: 16)
                }
                Image(systemName: section.group.category.symbol)
                    .foregroundStyle(section.group.category.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(section.group.title).font(.body.weight(.semibold))
                        if section.findings.count > 1 {
                            Text("\(section.findings.count)").font(.caption.monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(section.group.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Menu {
                    Button("Ignore “\(section.group.title)”") { model.ignore(group: section.group) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                if let command = section.group.command {
                    Button {
                        model.pendingCommand = .init(command: command, title: section.group.title)
                    } label: {
                        Label("Run cleanup", systemImage: "terminal")
                    }
                    .controlSize(.small)
                    .help("Runs: \(command)")
                }
                SafetyBadge(safety: section.safety)
                Text(ByteFormat.string(section.totalSize))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 78, alignment: .trailing)
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty Trash (\(ByteFormat.string(model.trashSize)))", role: .destructive) { model.emptyTrash() }
        } message: {
            Text("This permanently deletes every item in the Trash. It cannot be undone.")
        }
    }

    @State private var confirmEmptyTrash = false

    private func toggle(_ section: FindingSection) {
        let ids = section.findings.map(\.id)
        if checkboxState(section) == .on {
            ids.forEach { model.selectedFindings.remove($0) }
        } else {
            ids.forEach { model.selectedFindings.insert($0) }
        }
    }
}

private struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: CleanupFinding

    var body: some View {
        let selected = model.selectedFindings.contains(finding.id)
        HStack(spacing: 10) {
            Button {
                if selected { model.selectedFindings.remove(finding.id) } else { model.selectedFindings.insert(finding.id) }
            } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            NodeIcon(node: finding.node, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.title).lineLimit(1).truncationMode(.middle)
                Text(finding.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(ScanLocation.displayPath(finding.path).abbreviatingHome)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if finding.regenerable {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).help("Recreated automatically when needed")
            }
            Circle().fill(finding.safety.color).frame(width: 7, height: 7).help(finding.safety.title)
            Button { Workspace.reveal(finding.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
            Button { model.reveal(finding.node) } label: { Image(systemName: "square.grid.3x3") }
                .buttonStyle(.borderless).help("Show in Explorer")
            Text(ByteFormat.string(finding.size)).monospacedDigit().frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.leading, 26)
        .contextMenu {
            Button("Reveal in Finder") { Workspace.reveal(finding.path) }
            Button("Show in Explorer") { model.reveal(finding.node) }
            Button("Copy Path") { Workspace.copyPath(finding.path) }
            Divider()
            Button("Ignore This Item") { model.ignore(finding) }
            Button("Ignore All “\(finding.group.title)”") { model.ignore(group: finding.group) }
        }
    }
}
