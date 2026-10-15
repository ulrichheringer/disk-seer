import DiskSeerCore
import SwiftUI

/// Interactive nested treemap ("blocks") of a folder.
struct TreemapView: View {
    let root: FileNode
    let version: Int
    let extraBlocks: [FileNode]
    let colorMode: AppModel.ColorMode
    let maxDepth: Int
    @Binding var selection: FileNode?
    var onZoom: (FileNode) -> Void
    var onTrash: (FileNode) -> Void

    @State private var cells: [TreemapCell] = []
    @State private var hovered: TreemapCell?
    @State private var hoverLocation: CGPoint = .zero
    @State private var layoutKey = LayoutKey()

    struct LayoutKey: Equatable {
        var root: ObjectIdentifier?
        var size: CGSize = .zero
        var version = -1
        var depth = 0
        var extra = 0
    }

    var body: some View {
        GeometryReader { geo in
            let key = LayoutKey(root: root.id, size: geo.size, version: version, depth: maxDepth, extra: extraBlocks.count)
            ZStack(alignment: .topLeading) {
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    draw(context: &context, size: size)
                }
                .onAppear { relayout(key) }
                .onChange(of: key) { _, newKey in relayout(newKey) }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        hoverLocation = location
                        hovered = cell(at: location)
                    case .ended:
                        hovered = nil
                    }
                }
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { value in
                        if let hit = cell(at: value.location) { zoomTarget(for: hit).map(onZoom) }
                    }.exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                        if let hit = cell(at: value.location) {
                            selection = hit.isAggregate ? hit.node : (hit.node.isSynthetic ? nil : hit.node)
                        }
                    })
                )
                .contextMenu { contextMenu }

                if let hovered {
                    HoverTooltip(cell: hovered)
                        .offset(tooltipOffset(in: geo.size))
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Treemap of \(root.name)")
    }

    // MARK: Layout

    private func relayout(_ key: LayoutKey) {
        guard key != layoutKey else { return }
        layoutKey = key
        let layout = TreemapLayout(maxDepth: maxDepth, minimumCellArea: 30, headerHeight: 16, padding: 2)
        cells = layout.layout(root: root, in: CGRect(origin: .zero, size: key.size), extraBlocks: extraBlocks)
        hovered = nil
    }

    private func cell(at point: CGPoint) -> TreemapCell? {
        TreemapLayout.cell(at: point, in: cells)
    }

    private func zoomTarget(for cell: TreemapCell) -> FileNode? {
        TreemapLayout.zoomTarget(for: cell, root: root)
    }

    // MARK: Drawing

    private func baseColor(for node: FileNode, folderIndex: [ObjectIdentifier: Int]) -> Color {
        if node.isSynthetic {
            return node.name == "Free space" ? Color.secondary.opacity(0.18) : Color(white: 0.42)
        }
        switch colorMode {
        case .category:
            return node.category.color
        case .age:
            return AgePalette.color(for: node.newestModified)
        case .folder:
            // Color by top-level child of the current root.
            var cursor = node
            while let parent = cursor.parent, parent !== root { cursor = parent }
            let index = folderIndex[cursor.id] ?? 0
            return FolderPalette.colors[index % FolderPalette.colors.count]
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let selectedID = selection?.id
        var folderIndex: [ObjectIdentifier: Int] = [:]
        if colorMode == .folder {
            for (i, child) in root.children.sorted(by: { $0.size > $1.size }).enumerated() { folderIndex[child.id] = i }
        }
        for cell in cells {
            let rect = cell.rect
            guard rect.width >= 0.5, rect.height >= 0.5 else { continue }
            let color = baseColor(for: cell.node, folderIndex: folderIndex)
            if cell.isAggregate {
                drawAggregate(&context, rect: rect)
                continue
            }
            if cell.isLeaf {
                let inset = rect.insetBy(dx: 0.5, dy: 0.5)
                let path = Path(roundedRect: inset, cornerRadius: min(3, inset.width / 4, inset.height / 4))
                if cell.node.isSynthetic && cell.node.name == "Free space" {
                    context.fill(path, with: .color(color))
                    context.stroke(path, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else if inset.width * inset.height > 160 {
                    // Cushion-like shading: light top-left to darker bottom-right.
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [color.mix(with: .white, by: 0.28), color, color.mix(with: .black, by: 0.28)]),
                        startPoint: inset.origin, endPoint: CGPoint(x: inset.maxX, y: inset.maxY)))
                } else {
                    context.fill(path, with: .color(color))
                }
                if inset.width > 46 && inset.height > 26 {
                    drawLabel(&context, node: cell.node, in: inset)
                }
            } else {
                let path = Path(roundedRect: rect, cornerRadius: 4)
                context.fill(path, with: .color(color.opacity(0.16 + 0.04 * Double(min(cell.depth, 4)))))
                context.stroke(path, with: .color(color.opacity(0.55)), lineWidth: 0.75)
                if cell.hasHeader {
                    drawHeader(&context, node: cell.node, in: rect, color: color)
                }
            }
        }
        // Hover & selection outlines on top.
        if let hovered, hovered.node.id != selectedID {
            let path = Path(roundedRect: hovered.rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3)
            context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        if let selectedID, let cell = cells.first(where: { $0.node.id == selectedID && !$0.isAggregate }) {
            let path = Path(roundedRect: cell.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3)
            context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4)
            context.stroke(path, with: .color(.white), lineWidth: 2)
        }
    }

    private func drawAggregate(_ context: inout GraphicsContext, rect: CGRect) {
        let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2)
        context.fill(path, with: .color(Color.gray.opacity(0.28)))
        guard rect.width * rect.height > 1500 else { return }
        var hatch = Path()
        let step: CGFloat = 5
        var x = rect.minX - rect.height
        while x < rect.maxX {
            hatch.move(to: CGPoint(x: x, y: rect.maxY))
            hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        context.drawLayer { layer in
            layer.clip(to: path)
            layer.stroke(hatch, with: .color(.white.opacity(0.18)), lineWidth: 1)
        }
    }

    private func drawHeader(_ context: inout GraphicsContext, node: FileNode, in rect: CGRect, color: Color) {
        let headerRect = CGRect(x: rect.minX + 4, y: rect.minY + 1, width: rect.width - 8, height: 14)
        let size = ByteFormat.string(node.size)
        let title = Text(node.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
        let sizeText = Text(size).font(.system(size: 9.5, weight: .regular)).foregroundStyle(.secondary)
        let resolvedSize = context.resolve(sizeText)
        let sizeWidth = resolvedSize.measure(in: headerRect.size).width
        let showSize = rect.width > sizeWidth + 60
        var titleRect = headerRect
        if showSize { titleRect.size.width -= sizeWidth + 6 }
        context.draw(context.resolve(title), in: titleRect)
        if showSize {
            context.draw(resolvedSize, at: CGPoint(x: headerRect.maxX, y: headerRect.minY + 0.5), anchor: .topTrailing)
        }
    }

    private func drawLabel(_ context: inout GraphicsContext, node: FileNode, in rect: CGRect) {
        let padded = rect.insetBy(dx: 4, dy: 3)
        let fontSize: CGFloat = min(max(min(rect.width / 9, rect.height / 3.2), 9), 13)
        let name = Text(node.name).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(.white)
        let size = Text(ByteFormat.string(node.size)).font(.system(size: fontSize - 1.5)).foregroundStyle(.white.opacity(0.85))
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.55), radius: 1.2, x: 0, y: 0.5))
        let resolvedName = shadowed.resolve(name)
        shadowed.draw(resolvedName, in: CGRect(x: padded.minX, y: padded.minY, width: padded.width, height: fontSize + 4))
        if rect.height > fontSize * 2 + 10 {
            shadowed.draw(shadowed.resolve(size), in: CGRect(x: padded.minX, y: padded.minY + fontSize + 3, width: padded.width, height: fontSize + 2))
        }
    }

    // MARK: Interaction helpers

    private func tooltipOffset(in size: CGSize) -> CGSize {
        let width: CGFloat = 300, height: CGFloat = 92
        var x = hoverLocation.x + 16
        var y = hoverLocation.y + 16
        if x + width > size.width { x = hoverLocation.x - width - 12 }
        if y + height > size.height { y = hoverLocation.y - height - 12 }
        return CGSize(width: max(x, 4), height: max(y, 4))
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let cell = hovered, !cell.node.isSynthetic {
            let node = cell.node
            Text(node.name)
            Divider()
            if node.isContainer { Button("Zoom In") { onZoom(node) } }
            Button("Reveal in Finder") { Workspace.reveal(node.path) }
            Button("Quick Look") { Workspace.quickLook(node.path) }
            Button("Open in Terminal") { Workspace.openInTerminal(node.path) }
            Button("Copy Path") { Workspace.copyPath(node.path) }
            Divider()
            Button("Move to Trash…", role: .destructive) { onTrash(node) }
                .disabled(cell.isAggregate)
        }
    }
}

private struct HoverTooltip: View {
    let cell: TreemapCell

    var body: some View {
        let node = cell.node
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(node.isSynthetic ? Color.gray : node.category.color).frame(width: 8, height: 8)
                Text(cell.isAggregate ? "\(cell.aggregateCount) smaller items" : node.name)
                    .font(.callout.weight(.semibold)).lineLimit(1)
            }
            if !node.isSynthetic {
                Text(ScanLocation.displayPath(node.path).abbreviatingHome)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 10) {
                if !cell.isAggregate { Text(ByteFormat.string(node.size)).font(.caption.weight(.medium)).monospacedDigit() }
                if !node.isSynthetic && !cell.isAggregate {
                    Text(node.category.displayName).font(.caption).foregroundStyle(node.category.color)
                    if node.isContainer { Text("\(node.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary) }
                    Text(AgeFormat.relative(node.newestModified)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}
