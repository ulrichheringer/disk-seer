import Charts
import DiskSeerCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.hasFullDiskAccess { FullDiskAccessBanner() }
                if let volume = model.volume { VolumeCard(volume: volume) }
                statTiles
                if AppleIntelligence.isAvailable { AISummaryCard() }
                HStack(alignment: .top, spacing: 16) {
                    CategoryBreakdownCard()
                    TopItemsCard()
                }
                HStack(alignment: .top, spacing: 16) {
                    QuickWinsCard()
                    ChangesCard()
                }
                ScanInfoCard()
            }
            .padding(20)
        }
    }

    private var statTiles: some View {
        HStack(spacing: 12) {
            Button { model.section = .smartClean } label: {
                StatTile(title: "Safe to clean", value: ByteFormat.string(model.reclaimableSafe),
                         subtitle: "Caches, build output, package downloads", color: .green, symbol: "checkmark.shield.fill")
            }.buttonStyle(.plain)
            Button { model.section = .smartClean } label: {
                StatTile(title: "Worth reviewing", value: ByteFormat.string(model.reclaimableReview),
                         subtitle: "Old downloads, unused apps, VM disks…", color: .orange, symbol: "eye.fill")
            }.buttonStyle(.plain)
            Button { model.section = .apps } label: {
                StatTile(title: "Applications", value: model.appsLoading ? "…" : "\(model.apps.filter { !$0.isSystem }.count)",
                         subtitle: model.apps.isEmpty ? "Measuring…" : ByteFormat.string(model.apps.reduce(0) { $0 + $1.totalSize }) + " incl. data",
                         color: .blue, symbol: "app.badge.fill")
            }.buttonStyle(.plain)
            StatTile(title: "In the Trash", value: ByteFormat.string(model.trashSize),
                     subtitle: model.trashSize > 0 ? "Still uses disk space" : "Empty", color: .brown, symbol: "trash.fill")
        }
    }
}

private struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Full Disk Access for a complete picture").font(.headline)
                Text("macOS hides some folders (Mail, Safari, other apps' containers) until DiskSeer has Full Disk Access. \(model.scanStats.restricted) folders could not be read.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { model.openFullDiskAccessSettings() }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "internaldrive.fill").font(.title).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(volume.name).font(.title2.weight(.semibold))
                    Text("\(volume.format) · \(ByteFormat.string(volume.totalCapacity))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(ByteFormat.string(volume.availableCapacity)) free")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(volume.usedFraction > 0.9 ? .red : .primary)
                    if volume.purgeable > 0 {
                        Text("+ \(ByteFormat.string(volume.purgeable)) purgeable by macOS").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DiskUsageBar(segments: segments, total: volume.totalCapacity)
            if volume.usedFraction > 0.9 {
                Label("Your disk is \(Int(volume.usedFraction * 100))% full. macOS needs free space for updates, swap and snapshots — aim for at least 10–15%.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            }
        }
    }

    private var segments: [DiskUsageBar.Segment] {
        var result: [DiskUsageBar.Segment] = []
        let scanned = model.categoryTotals.reduce(0) { $0 + $1.size }
        let top = model.categoryTotals.prefix(8)
        for item in top {
            result.append(.init(label: item.category.displayName, size: item.size, color: item.category.color))
        }
        let rest = scanned - top.reduce(0) { $0 + $1.size }
        if rest > 0 { result.append(.init(label: "Other categories", size: rest, color: .gray.opacity(0.7))) }
        let outside = volume.usedCapacity - scanned
        if outside > 0 {
            result.append(.init(label: model.isEntireDisk ? "System & hidden" : (model.scanPath == ScanLocation.home ? "Outside home folder" : "Outside scanned folder"), size: outside, color: Color(white: 0.38)))
        }
        result.append(.init(label: "Free", size: volume.availableCapacity, color: Color.secondary.opacity(0.18)))
        return result
    }
}

private struct CategoryBreakdownCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "What's using space", symbol: "chart.pie") {
            let data = Array(model.categoryTotals.prefix(10))
            if data.isEmpty {
                Text("No data").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    Chart(data, id: \.category) { item in
                        SectorMark(angle: .value("Size", item.size), innerRadius: .ratio(0.58), angularInset: 1.2)
                            .foregroundStyle(item.category.color)
                            .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 170, height: 170)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(ByteFormat.string(model.root?.size ?? 0)).font(.headline).monospacedDigit()
                            Text("scanned").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(data, id: \.category) { item in
                            Button { model.section = .insights } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: item.category.symbol).foregroundStyle(item.category.color).frame(width: 16)
                                    Text(item.category.displayName).font(.callout).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(ByteFormat.string(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct TopItemsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Biggest folders", symbol: "folder") {
            if let root = model.root {
                let items = biggest(in: root)
                ForEach(items, id: \.id) { node in
                    Button { model.reveal(node) } label: {
                        HStack(spacing: 8) {
                            NodeIcon(node: node, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ScanLocation.displayPath(node.path).abbreviatingHome).font(.callout).lineLimit(1).truncationMode(.head)
                                Text(node.category.displayName).font(.caption2).foregroundStyle(node.category.color)
                            }
                            Spacer()
                            Text(ByteFormat.string(node.size)).font(.callout.monospacedDigit())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Largest folders that are not merely the parent of another listed folder.
    private func biggest(in root: FileNode) -> [FileNode] {
        var result: [FileNode] = []
        var frontier = root.children.filter(\.isContainer)
        let threshold = root.size / 40
        // Descend into a folder when one child holds most of it, so the list stays meaningful.
        while let next = frontier.max(by: { $0.size < $1.size }), result.count < 9 {
            frontier.removeAll { $0 === next }
            let dominant = next.children.filter(\.isContainer).max { $0.size < $1.size }
            if let dominant, next.kind == .directory, Double(dominant.size) > Double(next.size) * 0.55, dominant.size > threshold {
                frontier.append(contentsOf: next.children.filter(\.isContainer))
            } else {
                result.append(next)
            }
        }
        return result.sorted { $0.size > $1.size }
    }
}

private struct QuickWinsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Quick wins", symbol: "wand.and.stars") {
            let top = model.visibleFindingSections.sorted { $0.totalSize > $1.totalSize }.prefix(7)
            if top.isEmpty {
                Text("Nothing obvious to clean. 🎉").foregroundStyle(.secondary)
            }
            ForEach(Array(top)) { section in
                Button { model.section = .smartClean } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.group.category.symbol).foregroundStyle(section.group.category.color).frame(width: 18)
                        Text(section.group.title).font(.callout).lineLimit(1)
                        Spacer()
                        Circle().fill(section.safety.color).frame(width: 7, height: 7)
                        Text(ByteFormat.string(section.totalSize)).font(.callout.monospacedDigit())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ChangesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Changes since last scan", symbol: "chart.line.uptrend.xyaxis") {
            if let date = model.previousScanDate {
                Text("Compared with \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                if model.changes.isEmpty {
                    Text("No folder changed by more than 100 MB.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.changes.prefix(7)) { change in
                    HStack {
                        Image(systemName: change.delta > 0 ? "arrow.up.right" : "arrow.down.right")
                            .foregroundStyle(change.delta > 0 ? .red : .green)
                        Text(change.path).font(.callout).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text((change.delta > 0 ? "+" : "") + ByteFormat.string(change.delta))
                            .font(.callout.monospacedDigit()).foregroundStyle(change.delta > 0 ? .red : .green)
                    }
                }
            } else {
                Text("DiskSeer remembers each scan. Scan again later to see which folders grew.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScanInfoCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.scanStats
        HStack(spacing: 18) {
            Label("\(stats.files.formatted()) files", systemImage: "doc")
            Label("\(stats.directories.formatted()) folders", systemImage: "folder")
            Label(String(format: "%.1f s", model.lastScanDuration), systemImage: "timer")
            if stats.restricted > 0 {
                Label("\(stats.restricted) restricted", systemImage: "lock").help("Folders macOS did not let DiskSeer read")
            }
            if !model.localSnapshots.isEmpty {
                Label("\(model.localSnapshots.count) Time Machine local snapshots", systemImage: "clock.arrow.circlepath")
                    .help("Local snapshots are purged automatically when space is needed")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct AISummaryCard: View {
    @Environment(AppModel.self) private var model
    @State private var summary: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Card(title: "Your cleanup plan", symbol: "apple.intelligence") {
            if let summary {
                Text(AppleIntelligence.markdown(summary)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Let Apple Intelligence turn this scan into a prioritized plan. Runs on-device.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    generate()
                } label: {
                    if loading { ProgressView().controlSize(.small) } else { Label(summary == nil ? "Create plan" : "Regenerate", systemImage: "sparkles") }
                }
                .disabled(loading)
                Spacer()
            }
        }
    }

    private func generate() {
        loading = true
        error = nil
        let volume = model.volume, scanned = model.root?.size ?? 0, categories = model.categoryTotals
        let sections = model.visibleFindingSections, apps = model.apps
        Task {
            do {
                summary = try await AppleIntelligence.summarize(volume: volume, scanned: scanned, categories: categories,
                                                                sections: sections, apps: apps)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
