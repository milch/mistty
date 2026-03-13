import Foundation

enum NavigationDirection {
    case left, right, up, down
}

indirect enum PaneLayoutNode {
    case leaf(MisttyPane)
    case split(SplitDirection, PaneLayoutNode, PaneLayoutNode)
}

@MainActor
struct PaneLayout {
    var root: PaneLayoutNode

    init(pane: MisttyPane) {
        root = .leaf(pane)
    }

    var leaves: [MisttyPane] {
        if isEmpty { return [] }
        return Self.collectLeaves(root)
    }

    private static func collectLeaves(_ node: PaneLayoutNode) -> [MisttyPane] {
        switch node {
        case .leaf(let pane):
            return [pane]
        case .split(_, let a, let b):
            return collectLeaves(a) + collectLeaves(b)
        }
    }

    /// Returns true if the pane was removed. If removing the last pane,
    /// `leaves` will be empty — the caller should handle that (e.g. close the tab).
    @discardableResult
    mutating func remove(pane: MisttyPane) -> Bool {
        if let newRoot = Self.removeNode(root, target: pane.id) {
            root = newRoot
            return true
        } else {
            // The entire tree was just this one pane — mark as empty
            isEmpty = true
            return true
        }
    }

    private(set) var isEmpty = false

    private static func removeNode(_ node: PaneLayoutNode, target: UUID) -> PaneLayoutNode? {
        switch node {
        case .leaf(let p) where p.id == target:
            return nil // Remove this leaf
        case .leaf:
            return node // Not the target, keep it
        case .split(let dir, let a, let b):
            let newA = removeNode(a, target: target)
            let newB = removeNode(b, target: target)
            switch (newA, newB) {
            case (nil, nil): return nil
            case (nil, let remaining): return remaining
            case (let remaining, nil): return remaining
            case (let left?, let right?): return .split(dir, left, right)
            }
        }
    }

    mutating func split(pane: MisttyPane, direction: SplitDirection, directory: URL? = nil) {
        let newPane = MisttyPane()
        newPane.directory = directory
        root = Self.insertSplit(root, target: pane.id, direction: direction, newPane: newPane)
    }

    private static func insertSplit(
        _ node: PaneLayoutNode,
        target: UUID,
        direction: SplitDirection,
        newPane: MisttyPane
    ) -> PaneLayoutNode {
        switch node {
        case .leaf(let p) where p.id == target:
            return .split(direction, .leaf(p), .leaf(newPane))
        case .leaf:
            return node
        case .split(let dir, let a, let b):
            return .split(
                dir,
                insertSplit(a, target: target, direction: direction, newPane: newPane),
                insertSplit(b, target: target, direction: direction, newPane: newPane)
            )
        }
    }

    // MARK: - Pane Navigation

    func adjacentPane(from pane: MisttyPane, direction: NavigationDirection) -> MisttyPane? {
        guard let path = Self.findPath(root, target: pane.id) else { return nil }
        return Self.findAdjacent(root, path: path, direction: direction)
    }

    private enum PathStep { case left, right }

    private static func findPath(_ node: PaneLayoutNode, target: UUID) -> [PathStep]? {
        switch node {
        case .leaf(let p):
            return p.id == target ? [] : nil
        case .split(_, let a, let b):
            if let path = findPath(a, target: target) {
                return [.left] + path
            }
            if let path = findPath(b, target: target) {
                return [.right] + path
            }
            return nil
        }
    }

    private static func findAdjacent(
        _ root: PaneLayoutNode,
        path: [PathStep],
        direction: NavigationDirection
    ) -> MisttyPane? {
        let splitDir: SplitDirection
        let fromSide: PathStep
        switch direction {
        case .left:  splitDir = .horizontal; fromSide = .right
        case .right: splitDir = .horizontal; fromSide = .left
        case .up:    splitDir = .vertical;   fromSide = .right
        case .down:  splitDir = .vertical;   fromSide = .left
        }

        // Walk the tree following the path, collecting (node, step) pairs
        var nodes: [(PaneLayoutNode, PathStep)] = []
        var current = root
        for step in path {
            guard case .split(_, let a, let b) = current else { break }
            nodes.append((current, step))
            current = (step == .left) ? a : b
        }

        // Walk backwards looking for a matching split where we came from the correct side
        for (node, step) in nodes.reversed() {
            guard case .split(let dir, let a, let b) = node else { continue }
            if dir == splitDir && step == fromSide {
                let otherSubtree = (step == .left) ? b : a
                return (direction == .left || direction == .up)
                    ? lastLeaf(otherSubtree)
                    : firstLeaf(otherSubtree)
            }
        }
        return nil
    }

    private static func firstLeaf(_ node: PaneLayoutNode) -> MisttyPane? {
        switch node {
        case .leaf(let p): return p
        case .split(_, let a, _): return firstLeaf(a)
        }
    }

    private static func lastLeaf(_ node: PaneLayoutNode) -> MisttyPane? {
        switch node {
        case .leaf(let p): return p
        case .split(_, _, let b): return lastLeaf(b)
        }
    }
}
