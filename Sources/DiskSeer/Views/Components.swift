import AppKit
import DiskSeerCore
import SwiftUI

struct CategoryChip: View {
    let category: FileCategory
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: category.symbol).font(.caption2)
            if !compact { Text(category.displayName).font(.caption.weight(.medium)) }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(category.color.opacity(0.18), in: Capsule())
        .foregroundStyle(category.color)
        .help(category.displayName)
    }
}

struct SafetyBadge: View {
    let safety: CleanupSafety

    var body: some View {
        Label(safety.title, systemImage: safety.symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(safety.color.opacity(0.15), in: Capsule())
            .foregroundStyle(safety.color)
            .labelStyle(.titleAndIcon)
    }
}

struct SizeText: View {
    let bytes: Int64
    var body: some View {
        Text(ByteFormat.string(bytes)).monospacedDigit()
    }
}

/// Horizontal proportional bar.
struct ProportionBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(color.gradient)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
            }
        }
        .frame(height: 6)
    }
}

struct FileIcon: View {
    let path: String
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: Workspace.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct NodeIcon: View {
    let node: FileNode
    var size: CGFloat = 18

    var body: some View {
        if node.isSynthetic {
            Image(systemName: node.name == "Free space" ? "circle.dashed" : "lock.shield")
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        } else {
            FileIcon(path: node.path, size: size)
        }
    }
}

/// Card container used throughout the dashboard.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                    Text(title).font(.headline)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String?
    var color: Color = .accentColor
    var symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Tri-state checkbox for groups.
struct TriStateCheckbox: View {
    enum State { case on, off, mixed }
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : (state == .mixed ? "minus.square.fill" : "square"))
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .font(.body)
        }
        .buttonStyle(.plain)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

struct DiskUsageBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let label: String
        let size: Int64
        let color: Color
    }

    let segments: [Segment]
    let total: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(segments) { segment in
                        let width = geo.size.width * CGFloat(Double(segment.size) / Double(max(total, 1)))
                        if width > 0.5 {
                            Rectangle().fill(segment.color.gradient)
                                .frame(width: max(width - 1.5, 0.5))
                                .help("\(segment.label): \(ByteFormat.string(segment.size))")
                        }
                    }
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            FlowLegend(items: segments.map { ($0.label, $0.color, $0.size) })
        }
    }
}

struct FlowLegend: View {
    let items: [(String, Color, Int64)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Circle().fill(item.1).frame(width: 8, height: 8)
                    Text(item.0).font(.caption).lineLimit(1)
                    Text(ByteFormat.string(item.2)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}
