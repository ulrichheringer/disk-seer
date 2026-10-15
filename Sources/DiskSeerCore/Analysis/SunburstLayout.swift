import Foundation

/// One arc of a sunburst ("rings") chart.
public struct SunburstSegment: Sendable {
    public let node: FileNode
    /// Ring index, 1 = innermost ring around the center.
    public let depth: Int
    /// Angles in radians, clockwise from 12 o'clock, within 0...2π.
    public let startAngle: Double
    public let endAngle: Double
    /// Number of small children merged into this arc (0 for a real item).
    public let aggregateCount: Int

    public var isAggregate: Bool { aggregateCount > 0 }
    public var span: Double { endAngle - startAngle }
}

/// Radial partition layout: each ring shows one level of the hierarchy.
public struct SunburstLayout: Sendable {
    public var maxDepth: Int
    /// Arcs smaller than this (radians) are merged into an aggregate arc.
    public var minimumAngle: Double

    public init(maxDepth: Int = 5, minimumAngle: Double = 0.006) {
        self.maxDepth = maxDepth
        self.minimumAngle = minimumAngle
    }

    public func layout(root: FileNode) -> [SunburstSegment] {
        var segments: [SunburstSegment] = []
        segments.reserveCapacity(4096)
        place(children: root.children, of: root, total: root.size, from: 0, to: 2 * .pi, depth: 1, into: &segments)
        return segments
    }

    private func place(children: [FileNode], of parent: FileNode, total: Int64, from start: Double, to end: Double,
                       depth: Int, into segments: inout [SunburstSegment]) {
        guard depth <= maxDepth, total > 0 else { return }
        let span = end - start
        var angle = start
        var tinyCount = 0
        var tinyStart = 0.0
        for child in children.filter({ $0.size > 0 }).sorted(by: { $0.size > $1.size }) {
            let width = span * Double(child.size) / Double(total)
            if width < minimumAngle {
                if tinyCount == 0 { tinyStart = angle }
                tinyCount += 1
                angle += width
                continue
            }
            segments.append(SunburstSegment(node: child, depth: depth, startAngle: angle, endAngle: angle + width, aggregateCount: 0))
            if child.kind == .directory && !child.children.isEmpty {
                place(children: child.children, of: child, total: child.size, from: angle, to: angle + width, depth: depth + 1, into: &segments)
            }
            angle += width
        }
        if tinyCount > 0 && angle - tinyStart > 0.0005 {
            segments.append(SunburstSegment(node: parent, depth: depth, startAngle: tinyStart, endAngle: angle, aggregateCount: tinyCount))
        }
    }

    /// Hit test: which segment lies at the given polar coordinate (angle clockwise from 12 o'clock).
    public static func segment(in segments: [SunburstSegment], depth: Int, angle: Double) -> SunburstSegment? {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return segments.first { $0.depth == depth && a >= $0.startAngle && a < $0.endAngle }
    }
}
