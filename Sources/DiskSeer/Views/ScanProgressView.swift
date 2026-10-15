import DiskSeerCore
import SwiftUI

struct ScanProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.scanStats
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 10)
                if let volume = model.volume, volume.usedCapacity > 0 {
                    Circle()
                        .trim(from: 0, to: min(Double(stats.bytes) / Double(max(expectedBytes(volume), 1)), 0.98))
                        .stroke(Color.accentColor.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: stats.bytes)
                }
                VStack(spacing: 2) {
                    Text(ByteFormat.string(stats.bytes)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("measured").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, height: 170)

            Text("Scanning \(model.displayName)…").font(.title2.weight(.semibold))
            HStack(spacing: 24) {
                stat("\(stats.files.formatted())", "files")
                stat("\(stats.directories.formatted())", "folders")
                stat(String(format: "%.1f s", stats.elapsed), "elapsed")
                stat(stats.elapsed > 0.5 ? "\(Int(Double(stats.files) / stats.elapsed).formatted())" : "–", "files/s")
            }
            Text(ScanLocation.displayPath(stats.currentPath).abbreviatingHome)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 600)
            Button("Cancel") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Rough size to expect for the progress ring.
    private func expectedBytes(_ volume: VolumeInfo) -> Int64 {
        model.isEntireDisk ? Int64(Double(volume.usedCapacity) * 0.9) : max(Int64(Double(volume.usedCapacity) * 0.5), 1)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
