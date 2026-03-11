import Foundation

indirect enum PaneLayoutNode {
    case leaf(MisttyPane)
    case split(SplitDirection, PaneLayoutNode, PaneLayoutNode)
}

struct PaneLayout {
    var root: PaneLayoutNode

    init(pane: MisttyPane) {
        root = .leaf(pane)
    }

    var leaves: [MisttyPane] {
        Self.collectLeaves(root)
    }

    private static func collectLeaves(_ node: PaneLayoutNode) -> [MisttyPane] {
        switch node {
        case .leaf(let pane):
            return [pane]
        case .split(_, let a, let b):
            return collectLeaves(a) + collectLeaves(b)
        }
    }

    mutating func split(pane: MisttyPane, direction: SplitDirection) {
        let newPane = MisttyPane()
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
}
