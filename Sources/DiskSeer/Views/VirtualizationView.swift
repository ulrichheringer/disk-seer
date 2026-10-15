import DiskSeerCore
import SwiftUI

struct VirtualizationView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Docker & Virtual Machines").font(.title2.weight(.semibold))
                        Text("Container engines and VMs keep everything in big disk images (Docker.raw, data.img, .vhdx, .qcow2). They grow but rarely shrink on their own.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.dockerLoading { ProgressView().controlSize(.small) }
                    Button { model.loadVirtualization() } label: { Image(systemName: "arrow.clockwise") }
                }

                Card(title: "Virtual disk images", symbol: "externaldrive") {
                    if model.virtualDisks.isEmpty {
                        Text(model.dockerLoading ? "Looking for disk images…" : "No Docker or VM disk images found.").foregroundStyle(.secondary)
                    }
                    ForEach(model.virtualDisks) { disk in
                        HStack(spacing: 10) {
                            Image(systemName: "cylinder.split.1x2").font(.title3).foregroundStyle(FileCategory.virtualMachines.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(disk.product).font(.body.weight(.semibold))
                                Text(disk.path.abbreviatingHome).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if disk.logical > disk.allocated * 2 {
                                    Text("Sparse file: up to \(ByteFormat.string(disk.logical)), actually using \(ByteFormat.string(disk.allocated)).")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let command = disk.pruneCommand {
                                Button {
                                    model.pendingCommand = .init(command: command, title: "Prune \(disk.product)")
                                } label: { Label("Prune unused data", systemImage: "scissors") }
                                    .help(command)
                            }
                            Button { Workspace.reveal(disk.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                            Text(ByteFormat.string(disk.allocated)).font(.title3.weight(.semibold).monospacedDigit())
                        }
                        .padding(.vertical, 4)
                    }
                }

                Card(title: "Docker engine", symbol: "shippingbox") {
                    if let usage = model.dockerUsage {
                        if let context = usage.context { Text("Context: \(context)").font(.caption).foregroundStyle(.secondary) }
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            GridRow {
                                Text("Type").font(.caption.weight(.semibold))
                                Text("Total").font(.caption.weight(.semibold))
                                Text("Active").font(.caption.weight(.semibold))
                                Text("Size").font(.caption.weight(.semibold))
                                Text("Reclaimable").font(.caption.weight(.semibold))
                            }
                            Divider().gridCellColumns(5)
                            ForEach(usage.rows) { row in
                                GridRow {
                                    Text(row.type)
                                    Text(row.total).monospacedDigit()
                                    Text(row.active).monospacedDigit()
                                    Text(row.size).monospacedDigit()
                                    Text(row.reclaimable).monospacedDigit().foregroundStyle(.green)
                                }
                            }
                        }
                        Divider()
                        HStack(spacing: 8) {
                            commandButton("Remove stopped containers", "docker container prune -f")
                            commandButton("Remove dangling images", "docker image prune -f")
                            commandButton("Clear build cache", "docker builder prune -af")
                        }
                        HStack(spacing: 8) {
                            commandButton("Remove unused images", "docker image prune -af")
                            commandButton("Remove unused volumes", "docker volume prune -af", caution: true)
                            commandButton("Full prune", "docker system prune -af --volumes", caution: true)
                        }
                        Text("Volumes may contain databases. Pruning only removes data not used by any container.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(CommandRunner.which("docker") == nil
                             ? "Docker CLI not found."
                             : "Docker engine is not running. Start Docker Desktop / OrbStack / Colima to see reclaimable space.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let root = model.root {
                    Card(title: "Largest VM & container data in this scan", symbol: "server.rack") {
                        let items = topVirtualization(in: root)
                        if items.isEmpty { Text("None found.").foregroundStyle(.secondary) }
                        ForEach(items, id: \.id) { node in
                            Button { model.reveal(node) } label: {
                                HStack {
                                    NodeIcon(node: node, size: 18)
                                    Text(ScanLocation.displayPath(node.path).abbreviatingHome).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    SizeText(bytes: node.size)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Card(title: "Tips", symbol: "lightbulb") {
                    VStack(alignment: .leading, spacing: 6) {
                        tip("Docker Desktop: Settings › Resources › Disk image size lets you shrink the virtual disk after pruning.")
                        tip("OrbStack releases freed space automatically after `docker system prune`.")
                        tip("WSL / Hyper-V .vhdx files (e.g. copied from Windows) can be compacted with `Optimize-VHD` on Windows or deleted if unused.")
                        tip("Time Machine local snapshots (\(model.localSnapshots.count)) are deleted automatically by macOS when space runs low.")
                    }
                }
            }
            .padding(20)
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commandButton(_ title: String, _ command: String, caution: Bool = false) -> some View {
        Button {
            model.pendingCommand = .init(command: command, title: title)
        } label: {
            Label(title, systemImage: caution ? "exclamationmark.triangle" : "scissors")
        }
        .help(command)
    }

    private func topVirtualization(in root: FileNode) -> [FileNode] {
        var result: [FileNode] = []
        root.walk { node in
            if node.category == .virtualMachines && node.size > 50_000_000 {
                result.append(node)
                return false
            }
            return node.isContainer && node.size > 50_000_000
        }
        return Array(result.sorted { $0.size > $1.size }.prefix(10))
    }
}
