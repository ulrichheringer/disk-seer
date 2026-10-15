import Foundation

/// A node in the scanned file-system tree.
///
/// Nodes are reference types so the tree can be shared cheaply between the
/// scanner, the analyzers and the UI. Mutation only happens during scanning
/// (each node is populated by exactly one thread) and when items are removed
/// after a cleanup, which is always performed on the main actor.
public final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    public enum Kind: UInt8, Sendable {
        case file
        case directory
        case package
        case symlink
        /// Not a real file: e.g. "free space" or "hidden system space" blocks.
        case synthetic
    }

    /// For the root node this is the absolute path, for every other node the file name.
    public let name: String
    public internal(set) weak var parent: FileNode?
    public internal(set) var children: [FileNode]
    /// Bytes actually allocated on disk (st_blocks * 512), aggregated for directories.
    public internal(set) var size: Int64
    /// Logical (apparent) size in bytes, aggregated for directories.
    public internal(set) var logicalSize: Int64
    /// Number of regular files contained in this subtree (1 for a file).
    public internal(set) var fileCount: Int
    public let kind: Kind
    /// Modification date as seconds since 1970.
    public let modified: TimeInterval
    /// Access date as seconds since 1970.
    public let accessed: TimeInterval
    /// Most recent modification date anywhere in the subtree.
    public internal(set) var newestModified: TimeInterval
    /// The scanner could not read this directory (permissions / sandbox / TCC).
    public internal(set) var isRestricted: Bool
    /// Category assigned by the classification pass (cached for fast rendering).
    public internal(set) var category: FileCategory = .other
    /// Hard-linked file already counted elsewhere.
    public internal(set) var isHardLinkDuplicate: Bool = false

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    public init(
        name: String,
        kind: Kind,
        size: Int64 = 0,
        logicalSize: Int64 = 0,
        modified: TimeInterval = 0,
        accessed: TimeInterval = 0,
        children: [FileNode] = [],
        isRestricted: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.size = size
        self.logicalSize = logicalSize
        self.modified = modified
        self.accessed = accessed
        self.newestModified = modified
        self.children = children
        self.isRestricted = isRestricted
        self.fileCount = (kind == .file) ? 1 : 0
        for child in children { child.parent = self }
        if !children.isEmpty { recomputeAggregates() }
    }

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    // MARK: - Derived properties

    public var isContainer: Bool { kind == .directory || kind == .package }
    public var isSynthetic: Bool { kind == .synthetic }

    /// Absolute path of this node.
    public var path: String {
        guard let parent else { return name }
        var parts: [String] = [name]
        var cursor: FileNode? = parent
        while let node = cursor {
            if node.parent == nil {
                let base = node.name == "/" ? "" : node.name
                return base + "/" + parts.reversed().joined(separator: "/")
            }
            parts.append(node.name)
            cursor = node.parent
        }
        return parts.reversed().joined(separator: "/")
    }

    public var fileExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    public var depth: Int {
        var d = 0
        var cursor = parent
        while let node = cursor { d += 1; cursor = node.parent }
        return d
    }

    public var root: FileNode {
        var cursor = self
        while let p = cursor.parent { cursor = p }
        return cursor
    }

    /// Chain from the root to this node (inclusive).
    public var ancestry: [FileNode] {
        var chain: [FileNode] = [self]
        var cursor = parent
        while let node = cursor { chain.append(node); cursor = node.parent }
        return chain.reversed()
    }

    public func isDescendant(of other: FileNode) -> Bool {
        var cursor = parent
        while let node = cursor {
            if node === other { return true }
            cursor = node.parent
        }
        return false
    }

    /// Children sorted by size, largest first.
    public var sortedChildren: [FileNode] { children.sorted { $0.size > $1.size } }

    public func child(named name: String) -> FileNode? {
        children.first { $0.name == name }
    }

    /// Resolve a relative path ("a/b/c") below this node.
    public func descendant(atRelativePath relative: String) -> FileNode? {
        var cursor: FileNode? = self
        for part in relative.split(separator: "/") where !part.isEmpty {
            cursor = cursor?.child(named: String(part))
            if cursor == nil { return nil }
        }
        return cursor
    }

    /// Find a node by absolute path, if it lives below this (root) node.
    public func node(atPath absolute: String) -> FileNode? {
        let base = path
        if absolute == base { return self }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard absolute.hasPrefix(prefix) else { return nil }
        return descendant(atRelativePath: String(absolute.dropFirst(prefix.count)))
    }

    // MARK: - Mutation

    func setChildren(_ newChildren: [FileNode]) {
        for child in newChildren { child.parent = self }
        children = newChildren
    }

    /// Recompute size / counts from the direct children (non-recursive).
    /// Directory entries themselves occupy a negligible amount of space on APFS,
    /// so a container's size is the sum of its children.
    func recomputeAggregates() {
        guard isContainer || (isSynthetic && !children.isEmpty) else { return }
        var s: Int64 = 0
        var l: Int64 = 0
        var count = 0
        var newest = modified
        for child in children {
            s += child.size
            l += child.logicalSize
            count += child.fileCount
            if child.newestModified > newest { newest = child.newestModified }
        }
        size = s
        logicalSize = l
        fileCount = count
        newestModified = newest
    }

    /// Remove `child` from this node and propagate the size change upwards.
    @discardableResult
    public func removeChild(_ child: FileNode) -> Bool {
        guard let index = children.firstIndex(where: { $0 === child }) else { return false }
        children.remove(at: index)
        child.parent = nil
        var cursor: FileNode? = self
        while let node = cursor {
            node.size -= child.size
            node.logicalSize -= child.logicalSize
            node.fileCount -= child.fileCount
            cursor = node.parent
        }
        return true
    }

    /// Detach this node from the tree (after it was moved to the Trash).
    @discardableResult
    public func detachFromParent() -> Bool {
        parent?.removeChild(self) ?? false
    }

    // MARK: - Traversal

    /// Depth-first pre-order traversal. Return `false` from `body` to skip the subtree.
    public func walk(_ body: (FileNode) -> Bool) {
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            if body(node) {
                stack.append(contentsOf: node.children)
            }
        }
    }

    /// Visit every node in the subtree.
    public func forEach(_ body: (FileNode) -> Void) {
        walk { body($0); return true }
    }

    public var totalNodeCount: Int {
        var n = 0
        forEach { _ in n += 1 }
        return n
    }

    /// The `limit` largest regular files in the subtree.
    public func largestFiles(limit: Int, minimumSize: Int64 = 0) -> [FileNode] {
        var heap = TopK<FileNode>(capacity: limit) { $0.size < $1.size }
        forEach { node in
            if (node.kind == .file || node.kind == .package) && node.size >= minimumSize {
                heap.insert(node)
            }
        }
        return heap.sortedDescending()
    }

    func setCategory(_ category: FileCategory) { self.category = category }
    func markHardLinkDuplicate() { isHardLinkDuplicate = true }
}

/// Bounded collection keeping the K largest elements according to `less`.
public struct TopK<Element> {
    private var storage: [Element] = []
    private let capacity: Int
    private let less: (Element, Element) -> Bool

    public init(capacity: Int, less: @escaping (Element, Element) -> Bool) {
        self.capacity = max(capacity, 0)
        self.less = less
        storage.reserveCapacity(self.capacity)
    }

    public mutating func insert(_ element: Element) {
        guard capacity > 0 else { return }
        if storage.count < capacity {
            storage.append(element)
            siftUp(storage.count - 1)
        } else if less(storage[0], element) {
            storage[0] = element
            siftDown(0)
        }
    }

    public func sortedDescending() -> [Element] {
        storage.sorted { less($1, $0) }
    }

    // Min-heap on `less`.
    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if less(storage[child], storage[parent]) {
                storage.swapAt(child, parent)
                child = parent
            } else { return }
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < storage.count && less(storage[left], storage[smallest]) { smallest = left }
            if right < storage.count && less(storage[right], storage[smallest]) { smallest = right }
            if smallest == parent { return }
            storage.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
