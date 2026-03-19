import Foundation

enum StandardLayout: Sendable {
  case evenHorizontal, evenVertical, mainHorizontal, mainVertical, tiled
}

@MainActor
struct LayoutEngine {
  static func apply(_ layout: StandardLayout, to panes: [MisttyPane]) -> PaneLayoutNode {
    guard !panes.isEmpty else { return .empty }
    guard panes.count > 1 else { return .leaf(panes[0]) }

    switch layout {
    case .evenHorizontal: return evenSplit(.horizontal, panes)
    case .evenVertical: return evenSplit(.vertical, panes)
    case .mainHorizontal: return mainSplit(.horizontal, panes)
    case .mainVertical: return mainSplit(.vertical, panes)
    case .tiled: return tiled(panes)
    }
  }

  // MARK: - Even split

  /// Left-leaning chain of splits. Each level gives 1/N of the space to the left child.
  private static func evenSplit(_ direction: SplitDirection, _ panes: [MisttyPane])
    -> PaneLayoutNode
  {
    assert(panes.count >= 2)
    if panes.count == 2 {
      return .split(direction, .leaf(panes[0]), .leaf(panes[1]), 0.5)
    }
    let ratio = 1.0 / Double(panes.count)
    let rest = Array(panes.dropFirst())
    return .split(direction, .leaf(panes[0]), evenSplit(direction, rest), ratio)
  }

  // MARK: - Main split

  /// First pane gets 66% along the primary direction, rest are evenly split along the other.
  private static func mainSplit(_ direction: SplitDirection, _ panes: [MisttyPane])
    -> PaneLayoutNode
  {
    assert(panes.count >= 2)
    let main = panes[0]
    let rest = Array(panes.dropFirst())
    let secondaryDirection = direction.toggled
    let restNode: PaneLayoutNode
    if rest.count == 1 {
      restNode = .leaf(rest[0])
    } else {
      restNode = evenSplit(secondaryDirection, rest)
    }
    return .split(direction, .leaf(main), restNode, 0.66)
  }

  // MARK: - Tiled

  /// Grid layout: cols = ceil(sqrt(N)), rows = ceil(N/cols).
  /// Each row is an even horizontal split. Rows are combined with even vertical splits.
  /// Last row is padded with .empty to match column count.
  private static func tiled(_ panes: [MisttyPane]) -> PaneLayoutNode {
    assert(panes.count >= 2)
    let cols = Int(ceil(sqrt(Double(panes.count))))
    let rows = Int(ceil(Double(panes.count) / Double(cols)))

    var rowNodes: [PaneLayoutNode] = []
    for row in 0..<rows {
      let start = row * cols
      let end = min(start + cols, panes.count)
      let rowPanes = Array(panes[start..<end])
      let emptyCount = cols - rowPanes.count
      rowNodes.append(buildRow(rowPanes, emptyCount: emptyCount))
    }

    return evenSplitNodes(.vertical, rowNodes)
  }

  /// Build a single row: even horizontal split of panes, padded with .empty nodes.
  private static func buildRow(_ panes: [MisttyPane], emptyCount: Int) -> PaneLayoutNode {
    var nodes: [PaneLayoutNode] = panes.map { .leaf($0) }
    nodes.append(contentsOf: Array(repeating: PaneLayoutNode.empty, count: emptyCount))
    return evenSplitNodes(.horizontal, nodes)
  }

  /// Even split of arbitrary PaneLayoutNodes (not just panes).
  private static func evenSplitNodes(_ direction: SplitDirection, _ nodes: [PaneLayoutNode])
    -> PaneLayoutNode
  {
    assert(!nodes.isEmpty)
    if nodes.count == 1 { return nodes[0] }
    if nodes.count == 2 {
      return .split(direction, nodes[0], nodes[1], 0.5)
    }
    let ratio = 1.0 / Double(nodes.count)
    let rest = Array(nodes.dropFirst())
    return .split(direction, nodes[0], evenSplitNodes(direction, rest), ratio)
  }
}
