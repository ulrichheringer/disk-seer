import AppKit
import DiskSeerCore
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("DiskSeer").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("See what fills your Mac, understand it, and safely take your space back.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .padding(.top, 30)

            HStack(spacing: 16) {
                LocationCard(title: "Home Folder", subtitle: NSHomeDirectory(), symbol: "house.fill", color: .blue,
                             detail: "Fast. Your files, apps' data, caches and developer tools.") {
                    model.startScan(path: ScanLocation.home)
                }
                LocationCard(title: "Entire Disk", subtitle: model.volumes.first(where: \.isRoot)?.name ?? "Macintosh HD",
                             symbol: "internaldrive.fill", color: .purple,
                             detail: "Everything on the data volume, including /Applications and /Library.") {
                    model.startScan(path: ScanLocation.entireDisk)
                }
                LocationCard(title: "Choose Folder…", subtitle: "Any folder or external drive", symbol: "folder.fill.badge.plus", color: .teal,
                             detail: "Analyze a project folder, external disk or network share.") {
                    Workspace.chooseFolder().map(model.startScan)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900)

            if model.volumes.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Volumes").font(.headline)
                    ForEach(model.volumes) { volume in
                        Button { model.startScan(path: volume.isRoot ? ScanLocation.entireDisk : volume.path) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive").font(.title3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(volume.name).font(.callout.weight(.medium))
                                    ProportionBar(fraction: volume.usedFraction, color: volume.usedFraction > 0.9 ? .red : .accentColor)
                                        .frame(width: 260)
                                }
                                Spacer()
                                Text("\(ByteFormat.string(volume.availableCapacity)) free of \(ByteFormat.string(volume.totalCapacity))")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 900)
            } else if let volume = model.volumes.first {
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive")
                    Text(volume.name).font(.callout.weight(.medium))
                    ProportionBar(fraction: volume.usedFraction, color: volume.usedFraction > 0.9 ? .red : .accentColor).frame(width: 260)
                    Text("\(ByteFormat.string(volume.availableCapacity)) free of \(ByteFormat.string(volume.totalCapacity))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            if !model.hasFullDiskAccess {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Tip: grant Full Disk Access so DiskSeer can measure protected folders too.").font(.callout)
                    Button("Open Settings") { model.openFullDiskAccessSettings() }.controlSize(.small)
                }
            }
            Spacer()
            Text("Tip: drop any folder or drive here to analyze it.").font(.caption).foregroundStyle(.secondary)
            Text("DiskSeer never deletes anything permanently: items go to the Trash, protected system locations are locked.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.08), .clear], startPoint: .top, endPoint: .center)
        )
        .onAppear { model.volumes = VolumeInfo.mounted() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            model.startScan(path: url.path)
            return true
        }
    }
}

private struct LocationCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(color.gradient)
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Text("Scan").font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right.circle.fill")
                }
                .foregroundStyle(color)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovering ? color.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: hovering ? 2 : 1))
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
