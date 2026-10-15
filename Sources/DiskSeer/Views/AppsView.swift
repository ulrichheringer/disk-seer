import DiskSeerCore
import SwiftUI

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\Row.total, order: .reverse)]
    @State private var showSystem = false
    @State private var search = ""

    struct Row: Identifiable {
        let app: AppInfo
        var id: String { app.path }
        var name: String { app.name }
        var size: Int64 { app.size }
        var data: Int64 { app.dataSize }
        var total: Int64 { app.totalSize }
        var lastUsed: Double { app.lastUsed?.timeIntervalSince1970 ?? 0 }
    }

    private var rows: [Row] {
        model.apps
            .filter { showSystem || !$0.isSystem }
            .filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) || ($0.bundleID ?? "").lowercased().contains(search.lowercased()) }
            .map(Row.init)
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Applications").font(.title2.weight(.semibold))
                    Text("App size plus the data each app keeps in your Library. Uninstalling moves the app and its data to the Trash.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.appsLoading { ProgressView().controlSize(.small) }
                Toggle("Show Apple apps", isOn: $showSystem)
                TextField("Search apps", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                Button { model.loadApps() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            VSplitView {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("App", value: \.name) { row in
                        HStack(spacing: 8) {
                            FileIcon(path: row.app.path, size: 22)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.app.name).lineLimit(1)
                                Text([row.app.version.map { "v\($0)" }, row.app.isAppStore ? "App Store" : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .width(min: 180, ideal: 240)
                    TableColumn("App size", value: \.size) { row in SizeText(bytes: row.size) }.width(min: 70, ideal: 80)
                    TableColumn("Data", value: \.data) { row in
                        SizeText(bytes: row.data).foregroundStyle(.secondary)
                    }.width(min: 70, ideal: 80)
                    TableColumn("Total", value: \.total) { row in
                        SizeText(bytes: row.total).fontWeight(.semibold)
                    }.width(min: 70, ideal: 85)
                    TableColumn("Last opened", value: \.lastUsed) { row in
                        if let date = row.app.lastUsed {
                            let days = AgeFormat.days(since: date.timeIntervalSince1970)
                            Text((row.app.lastUsedIsEstimate ? "≈ " : "") + AgeFormat.relative(date.timeIntervalSince1970))
                                .foregroundStyle(days > 180 ? .orange : .secondary)
                                .help(row.app.lastUsedIsEstimate ? "Estimated from the last time the app wrote its data" : "Last opened (Spotlight)")
                        } else {
                            Text("Unknown").foregroundStyle(.tertiary)
                        }
                    }.width(min: 90, ideal: 110)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let apps = model.apps.filter { ids.contains($0.path) }
                    if apps.count == 1, let app = apps.first {
                        Button("Open") { Workspace.open(app.path) }
                        Button("Reveal in Finder") { Workspace.reveal(app.path) }
                        Divider()
                    }
                    if !apps.isEmpty {
                        Button("Uninstall…", role: .destructive) { uninstall(apps) }
                            .disabled(apps.contains { $0.isSystem })
                    }
                }
                .frame(minHeight: 260)

                detailPane
                    .frame(minHeight: 160)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        let selected = model.apps.filter { selection.contains($0.path) }
        if let app = selected.first, selected.count == 1 {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        FileIcon(path: app.path, size: 40)
                        VStack(alignment: .leading) {
                            Text(app.name).font(.headline)
                            Text(app.bundleID ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Reveal") { Workspace.reveal(app.path) }
                        Button(role: .destructive) { uninstall([app]) } label: { Label("Uninstall…", systemImage: "trash") }
                            .disabled(app.isSystem)
                    }
                    Text("Files that would be removed").font(.subheadline.weight(.semibold))
                    pathRow(app.path, size: app.size)
                    ForEach(app.dataPaths, id: \.self) { path in
                        pathRow(path, size: model.root?.node(atPath: path)?.size ?? 0)
                    }
                }
                .padding(16)
            }
        } else if !model.leftovers.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Leftovers of uninstalled apps").font(.headline)
                        Spacer()
                        Text(ByteFormat.string(model.leftovers.reduce(0) { $0 + $1.size })).monospacedDigit()
                        Button(role: .destructive) {
                            model.requestTrash(paths: model.leftovers.map { ($0.path, $0.size) }, title: "\(model.leftovers.count) leftover folders")
                        } label: { Label("Remove All…", systemImage: "trash") }
                    }
                    Text("Data in your Library whose app (bundle identifier) is not installed anymore.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.leftovers) { leftover in
                        HStack {
                            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                            Text(leftover.bundleID).lineLimit(1)
                            Text(leftover.location).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { Workspace.reveal(leftover.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                            SizeText(bytes: leftover.size).frame(width: 80, alignment: .trailing)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            EmptyStateView(symbol: "app.dashed", title: "Select an app", message: "See which files belong to it.")
        }
    }

    private func pathRow(_ path: String, size: Int64) -> some View {
        HStack {
            FileIcon(path: path, size: 16)
            Text(path.abbreviatingHome).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            if size > 0 { SizeText(bytes: size).font(.caption) }
        }
    }

    private func uninstall(_ apps: [AppInfo]) {
        var items: [(path: String, size: Int64)] = []
        for app in apps where !app.isSystem {
            items.append((app.path, app.size))
            for path in app.dataPaths {
                items.append((path, model.root?.node(atPath: path)?.size ?? 0))
            }
        }
        model.requestTrash(paths: items, title: apps.count == 1 ? "Uninstall \(apps[0].name)" : "Uninstall \(apps.count) apps")
    }
}
