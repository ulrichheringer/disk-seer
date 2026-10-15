import DiskSeerCore
import SwiftUI

/// DaisyDisk-style rings: the center is the current folder, each ring is one level deeper.
struct SunburstView: View {
    let root: FileNode
    let version: Int
    let colorMode: AppModel.ColorMode
    let maxDepth: Int
    @Binding var selection: FileNode?
    var onZoom: (FileNode) -> Void
    var onZoomOut: () -> Void
    var onTrash: (FileNode) -> Void

    @State private var segments: [SunburstSegment] = []
    @State private var hovered: SunburstSegment?
    @State private var hoverLocation: CGPoint = .zero
    @State private var key = Key()

    struct Key: Equatable { var root: ObjectIdentifier?; var version = -1; var depth = 0 }

    var body: some View {
        GeometryReader { geo in
            let geometry = RingGeometry(size: geo.size, rings: maxDepth)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(&context, geometry) }
                    .onAppear { relayout() }
                    .onChange(of: Key(root: root.id, version: version, depth: maxDepth)) { _, _ in relayout() }
                    .onContinuousHover { phase in
                        if case let .active(point) = phase {
                            hoverLocation = point
                            hovered = hit(point, geometry)
                        } else {
                            hovered = nil
                        }
                    }
                    .gesture(
                        SpatialTapGesture(count: 2).onEnded { value in
                            if geometry.isCenter(value.location) { onZoomOut(); return }
                            if let node = hit(value.location, geometry)?.node, node.isContainer { onZoom(node) }
                        }.exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                            if geometry.isCenter(value.location) { selection = root; return }
                            selection = hit(value.location, geometry)?.node
                        })
                    )
                    .contextMenu {
                        if let node = hovered?.node, hovered?.isAggregate == false {
                            Text(node.name)
                            Divider()
                            if node.isContainer { Button("Zoom In") { onZoom(node) } }
                            Button("Reveal in Finder") { Workspace.reveal(node.path) }
                            Button("Quick Look") { Workspace.quickLook(node.path) }
                            Button("Copy Path") { Workspace.copyPath(node.path) }
                            Divider()
                            Button("Move to Trash…", role: .destructive) { onTrash(node) }
                        }
                    }

                centerLabel(geometry)
                    .allowsHitTesting(false)

                if let hovered {
                    SegmentTooltip(segment: hovered)
                        .offset(x: min(hoverLocation.x + 16, geo.size.width - 300), y: min(hoverLocation.y + 16, geo.size.height - 90))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    struct RingGeometry {
        let center: CGPoint
        let inner: CGFloat
        let ringWidth: CGFloat

        init(size: CGSize, rings: Int) {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 8
            inner = radius * 0.24
            ringWidth = (radius - inner) / CGFloat(max(rings, 1))
        }

        func radii(depth: Int) -> (CGFloat, CGFloat) {
            (inner + CGFloat(depth - 1) * ringWidth + 1, inner + CGFloat(depth) * ringWidth)
        }

        func isCenter(_ p: CGPoint) -> Bool { hypot(p.x - center.x, p.y - center.y) < inner }

        /// Ring depth and clockwise angle from 12 o'clock for a point.
        func polar(_ p: CGPoint) -> (depth: Int, angle: Double)? {
            let dx = p.x - center.x, dy = p.y - center.y
            let distance = hypot(dx, dy)
            guard distance >= inner, ringWidth > 0 else { return nil }
            let depth = Int((distance - inner) / ringWidth) + 1
            var angle = atan2(Double(dx), Double(-dy))
            if angle < 0 { angle += 2 * .pi }
            return (depth, angle)
        }
    }

    private func relayout() {
        let newKey = Key(root: root.id, version: version, depth: maxDepth)
        guard newKey != key else { return }
        key = newKey
        segments = SunburstLayout(maxDepth: maxDepth).layout(root: root)
        hovered = nil
    }

    private func hit(_ point: CGPoint, _ g: RingGeometry) -> SunburstSegment? {
        guard let polar = g.polar(point) else { return nil }
        return SunburstLayout.segment(in: segments, depth: polar.depth, angle: polar.angle)
    }

    private func color(for segment: SunburstSegment) -> Color {
        if segment.isAggregate { return .gray.opacity(0.45) }
        let node = segment.node
        let base: Color
        switch colorMode {
        case .category: base = node.category.color
        case .age: base = AgePalette.color(for: node.newestModified)
        case .folder:
            var cursor = node
            while let parent = cursor.parent, parent !== root { cursor = parent }
            let index = root.children.firstIndex { $0 === cursor } ?? 0
            base = FolderPalette.colors[index % FolderPalette.colors.count]
        }
        return base.mix(with: .white, by: min(Double(segment.depth - 1) * 0.07, 0.35))
    }

    private func draw(_ context: inout GraphicsContext, _ g: RingGeometry) {
        let selectedID = selection?.id
        for segment in segments {
            let (r0, r1) = g.radii(depth: segment.depth)
            let path = arc(g.center, r0, r1, segment.startAngle, segment.endAngle)
            context.fill(path, with: .color(color(for: segment)))
            if segment.span > 0.01 {
                context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.9)), lineWidth: 0.8)
            }
        }
        if let hovered {
            let (r0, r1) = g.radii(depth: hovered.depth)
            context.stroke(arc(g.center, r0, r1, hovered.startAngle, hovered.endAngle), with: .color(.white), lineWidth: 1.5)
        }
        if let selectedID, let s = segments.first(where: { $0.node.id == selectedID && !$0.isAggregate }) {
            let (r0, r1) = g.radii(depth: s.depth)
            let path = arc(g.center, r0, r1, s.startAngle, s.endAngle)
            context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4)
            context.stroke(path, with: .color(.white), lineWidth: 2)
        }
        let centerCircle = Path(ellipseIn: CGRect(x: g.center.x - g.inner + 2, y: g.center.y - g.inner + 2,
                                                   width: (g.inner - 2) * 2, height: (g.inner - 2) * 2))
        context.fill(centerCircle, with: .color(Color.secondary.opacity(0.12)))
    }

    private func arc(_ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ a0: Double, _ a1: Double) -> Path {
        // Convert "clockwise from 12 o'clock" to SwiftUI angles (0 = 3 o'clock, clockwise in flipped coordinates).
        let start = Angle(radians: a0 - .pi / 2), end = Angle(radians: a1 - .pi / 2)
        var path = Path()
        path.addArc(center: c, radius: r1, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: c, radius: r0, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func centerLabel(_ g: RingGeometry) -> some View {
        VStack(spacing: 2) {
            Text(root.parent == nil ? ScanLocation.displayPath(root.name).abbreviatingHome : root.name)
                .font(.headline).lineLimit(2).multilineTextAlignment(.center)
            Text(ByteFormat.string(root.size)).font(.title3.weight(.bold)).monospacedDigit()
            if root.parent != nil {
                Text("double-click to go up").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: g.inner * 1.6)
        .position(g.center)
    }
}

private struct SegmentTooltip: View {
    let segment: SunburstSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(segment.isAggregate ? "\(segment.aggregateCount) smaller items" : segment.node.name)
                .font(.callout.weight(.semibold)).lineLimit(1)
            if !segment.isAggregate {
                Text(ScanLocation.displayPath(segment.node.path).abbreviatingHome)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(ByteFormat.string(segment.node.size)).font(.caption.weight(.medium)).monospacedDigit()
                    Text(segment.node.category.displayName).font(.caption).foregroundStyle(segment.node.category.color)
                    Text(AgeFormat.relative(segment.node.newestModified)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}
