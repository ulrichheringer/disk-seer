import CoreGraphics
import Foundation

/// One rectangle of a treemap.
public struct TreemapCell: Sendable {
    public let node: FileNode
    public let rect: CGRect
    public let depth: Int
    /// The cell is drawn as a solid block (file, package, or folder at max depth).
    public let isLeaf: Bool
    /// A folder title strip is drawn at the top of the cell.
    public let hasHeader: Bool
    /// Aggregate of many children too small to draw individually.
    public let aggregateCount: Int

    public var isAggregate: Bool { aggregateCount > 0 }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk) with nested folder headers.
public struct TreemapLayout: Sendable {
    public var maxDepth: Int = 6
    public var minimumCellArea: Double = 36
    public var headerHeight: Double = 15
    public var padding: Double = 2
    public var maxCells: Int = 12_000

    public init(maxDepth: Int = 6, minimumCellArea: Double = 36, headerHeight: Double = 15, padding: Double = 2) {
        self.maxDepth = maxDepth
        self.minimumCellArea = minimumCellArea
        self.headerHeight = headerHeight
        self.padding = padding
    }

    /// Compute the cells for `root` laid out inside `bounds`.
    /// `extraBlocks` are synthetic nodes (free space / hidden space) placed next to the root's children.
    public func layout(root: FileNode, in bounds: CGRect, extraBlocks: [FileNode] = []) -> [TreemapCell] {
        guard bounds.width > 1, bounds.height > 1 else { return [] }
        var cells: [TreemapCell] = []
        cells.reserveCapacity(2048)
        let children = visibleChildren(of: root) + extraBlocks.filter { $0.size > 0 }
        layoutChildren(children, parent: root, in: bounds, depth: 1, cells: &cells)
        return cells
    }

    private func visibleChildren(of node: FileNode) -> [FileNode] {
        node.children.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    private func layoutChildren(_ children: [FileNode], parent: FileNode, in rect: CGRect, depth: Int, cells: inout [TreemapCell]) {
        guard !children.isEmpty, rect.width >= 1, rect.height >= 1 else { return }
        let total = children.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0 else { return }
        let area = Double(rect.width * rect.height)

        // Children too small to draw are merged into one aggregate block.
        var drawable: [FileNode] = []
        var tinyCount = 0
        var tinySize = 0.0
        for child in children {
            let childArea = Double(child.size) / total * area
            if childArea < minimumCellArea || cells.count + drawable.count >= maxCells {
                tinyCount += 1
                tinySize += Double(child.size)
            } else {
                drawable.append(child)
            }
        }
        var values = drawable.map { Double($0.size) / total * area }
        if tinyCount > 0 { values.append(tinySize / total * area) }

        let rects = TreemapLayout.squarify(values: values, in: rect)
        for (index, child) in drawable.enumerated() {
            place(child, in: rects[index], depth: depth, cells: &cells)
        }
        if tinyCount > 0, let last = rects.last {
            cells.append(TreemapCell(node: parent, rect: last, depth: depth, isLeaf: true, hasHeader: false, aggregateCount: tinyCount))
        }
    }

    private func place(_ node: FileNode, in rect: CGRect, depth: Int, cells: inout [TreemapCell]) {
        let canDescend = node.kind == .directory && depth < maxDepth && !node.children.isEmpty
            && rect.width > padding * 2 + 6 && rect.height > padding * 2 + 6
        guard canDescend else {
            cells.append(TreemapCell(node: node, rect: rect, depth: depth, isLeaf: true, hasHeader: false, aggregateCount: 0))
            return
        }
        let header = rect.height > headerHeight * 2.4 && rect.width > 44
        cells.append(TreemapCell(node: node, rect: rect, depth: depth, isLeaf: false, hasHeader: header, aggregateCount: 0))
        var inner = rect.insetBy(dx: padding, dy: padding)
        if header {
            inner.origin.y += headerHeight - padding
            inner.size.height -= headerHeight - padding
        }
        guard inner.width > 2, inner.height > 2 else { return }
        layoutChildren(visibleChildren(of: node), parent: node, in: inner, depth: depth + 1, cells: &cells)
    }

    /// The deepest cell containing `point` (cells are emitted parents first).
    public static func cell(at point: CGPoint, in cells: [TreemapCell]) -> TreemapCell? {
        var best: TreemapCell?
        for cell in cells where cell.rect.contains(point) {
            if best == nil || cell.depth >= best!.depth { best = cell }
        }
        return best
    }

    /// Folder to open when the user double-clicks `cell` while viewing `root`.
    public static func zoomTarget(for cell: TreemapCell, root: FileNode) -> FileNode? {
        if cell.isAggregate { return cell.node === root ? nil : cell.node }
        if cell.node.isContainer && !cell.node.isSynthetic { return cell.node }
        // A file: open its folder, unless that is already the displayed root.
        guard let parent = cell.node.parent, parent !== root else { return nil }
        return parent
    }

    /// Squarified layout of `values` (already scaled to areas, sorted descending) into `rect`.
    public static func squarify(values: [Double], in rect: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        result.reserveCapacity(values.count)
        var remaining = rect
        var row: [Double] = []
        var index = 0

        func worst(_ row: [Double], side: Double) -> Double {
            guard let maxV = row.max(), let minV = row.min(), minV > 0 else { return .infinity }
            let sum = row.reduce(0, +)
            let s2 = sum * sum, w2 = side * side
            return max(w2 * maxV / s2, s2 / (w2 * minV))
        }

        func layoutRow(_ row: [Double]) {
            let sum = row.reduce(0, +)
            guard sum > 0 else {
                for _ in row { result.append(CGRect(x: remaining.minX, y: remaining.minY, width: 0, height: 0)) }
                return
            }
            if remaining.width >= remaining.height {
                // Column on the left.
                let width = min(CGFloat(sum) / max(remaining.height, 0.0001), remaining.width)
                var y = remaining.minY
                for v in row {
                    let h = CGFloat(v) / max(width, 0.0001)
                    result.append(CGRect(x: remaining.minX, y: y, width: width, height: h))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                // Row on top.
                let height = min(CGFloat(sum) / max(remaining.width, 0.0001), remaining.height)
                var x = remaining.minX
                for v in row {
                    let w = CGFloat(v) / max(height, 0.0001)
                    result.append(CGRect(x: x, y: remaining.minY, width: w, height: height))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(remaining.height - height, 0))
            }
        }

        while index < values.count {
            let side = Double(min(remaining.width, remaining.height))
            let value = values[index]
            if row.isEmpty || worst(row + [value], side: side) <= worst(row, side: side) {
                row.append(value)
                index += 1
            } else {
                layoutRow(row)
                row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { layoutRow(row) }
        return result
    }
}
