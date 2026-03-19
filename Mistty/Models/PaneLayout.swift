import Foundation

enum NavigationDirection {
  case left, right, up, down
}

indirect enum PaneLayoutNode {
  case leaf(MisttyPane)
  case empty
  case split(SplitDirection, PaneLayoutNode, PaneLayoutNode, CGFloat)
}

@MainActor
struct PaneLayout {
  var root: PaneLayoutNode

  init(pane: MisttyPane) {
    root = .leaf(pane)
  }

  init(root: PaneLayoutNode) {
    self.root = root
  }

  var leaves: [MisttyPane] {
    if isEmpty { return [] }
    return Self.collectLeaves(root)
  }

  private static func collectLeaves(_ node: PaneLayoutNode) -> [MisttyPane] {
    switch node {
    case .leaf(let pane):
      return [pane]
    case .empty:
      return []
    case .split(_, let a, let b, _):
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

  private static func removeNode(_ node: PaneLayoutNode, target: Int) -> PaneLayoutNode? {
    switch node {
    case .leaf(let p) where p.id == target:
      return nil  // Remove this leaf
    case .leaf:
      return node  // Not the target, keep it
    case .empty:
      return node
    case .split(let dir, let a, let b, let ratio):
      let newA = removeNode(a, target: target)
      let newB = removeNode(b, target: target)
      switch (newA, newB) {
      case (nil, nil): return nil
      case (nil, let remaining): return remaining
      case (let remaining, nil): return remaining
      case (let left?, let right?):
        // Collapse empty siblings so orphaned .empty nodes don't waste screen space
        if case .empty = left { return right }
        if case .empty = right { return left }
        return .split(dir, left, right, ratio)
      }
    }
  }

  mutating func split(pane: MisttyPane, direction: SplitDirection, newPane: MisttyPane) {
    root = Self.insertSplit(root, target: pane.id, direction: direction, newPane: newPane)
  }

  private static func insertSplit(
    _ node: PaneLayoutNode,
    target: Int,
    direction: SplitDirection,
    newPane: MisttyPane
  ) -> PaneLayoutNode {
    switch node {
    case .leaf(let p) where p.id == target:
      return .split(direction, .leaf(p), .leaf(newPane), 0.5)
    case .leaf:
      return node
    case .empty:
      return node
    case .split(let dir, let a, let b, let ratio):
      return .split(
        dir,
        insertSplit(a, target: target, direction: direction, newPane: newPane),
        insertSplit(b, target: target, direction: direction, newPane: newPane),
        ratio
      )
    }
  }

  // MARK: - Rotate

  mutating func rotateDirection(containing pane: MisttyPane) {
    root = Self.rotate(root, target: pane.id)
  }

  private static func rotate(_ node: PaneLayoutNode, target: Int) -> PaneLayoutNode {
    switch node {
    case .leaf, .empty:
      return node
    case .split(let dir, let a, let b, let ratio):
      // Check if target is a direct leaf child of this split
      let isDirectChild: Bool
      switch (a, b) {
      case (.leaf(let p), _) where p.id == target: isDirectChild = true
      case (_, .leaf(let p)) where p.id == target: isDirectChild = true
      default: isDirectChild = false
      }

      if isDirectChild {
        return .split(dir.toggled, a, b, ratio)
      }

      // Recurse
      return .split(dir, rotate(a, target: target), rotate(b, target: target), ratio)
    }
  }

  // MARK: - Resize

  mutating func resizeSplit(
    containing pane: MisttyPane, delta: CGFloat, along direction: SplitDirection? = nil
  ) {
    root = Self.adjustRatio(root, target: pane.id, delta: delta, along: direction)
  }

  private static func adjustRatio(
    _ node: PaneLayoutNode,
    target: Int,
    delta: CGFloat,
    along direction: SplitDirection?
  ) -> PaneLayoutNode {
    switch node {
    case .leaf, .empty:
      return node
    case .split(let dir, let a, let b, let ratio):
      let aContains = collectLeaves(a).contains { $0.id == target }
      let bContains = collectLeaves(b).contains { $0.id == target }
      guard aContains || bContains else { return node }

      // If this split matches the requested direction, adjust its ratio.
      // Positive delta moves the divider right/down (increases ratio = more space for side A).
      if direction == nil || direction == dir {
        return .split(dir, a, b, max(0.1, min(0.9, ratio + delta)))
      }

      // Direction doesn't match this split — recurse into the subtree containing the target
      if aContains {
        return .split(dir, adjustRatio(a, target: target, delta: delta, along: direction), b, ratio)
      } else {
        return .split(dir, a, adjustRatio(b, target: target, delta: delta, along: direction), ratio)
      }
    }
  }

  // MARK: - Pane Navigation

  func adjacentPane(from pane: MisttyPane, direction: NavigationDirection) -> MisttyPane? {
    guard let path = Self.findPath(root, target: pane.id) else { return nil }
    return Self.findAdjacent(root, path: path, direction: direction)
  }

  private enum PathStep { case left, right }

  private static func findPath(_ node: PaneLayoutNode, target: Int) -> [PathStep]? {
    switch node {
    case .leaf(let p):
      return p.id == target ? [] : nil
    case .empty:
      return nil
    case .split(_, let a, let b, _):
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
    case .left:
      splitDir = .horizontal
      fromSide = .right
    case .right:
      splitDir = .horizontal
      fromSide = .left
    case .up:
      splitDir = .vertical
      fromSide = .right
    case .down:
      splitDir = .vertical
      fromSide = .left
    }

    // Walk the tree following the path, collecting (node, step) pairs
    var nodes: [(PaneLayoutNode, PathStep)] = []
    var current = root
    for step in path {
      guard case .split(_, let a, let b, _) = current else { break }
      nodes.append((current, step))
      current = (step == .left) ? a : b
    }

    // Walk backwards looking for a matching split where we came from the correct side
    for (node, step) in nodes.reversed() {
      guard case .split(let dir, let a, let b, _) = node else { continue }
      if dir == splitDir && step == fromSide {
        let otherSubtree = (step == .left) ? b : a
        return (direction == .left || direction == .up)
          ? lastLeaf(otherSubtree)
          : firstLeaf(otherSubtree)
      }
    }
    return nil
  }

  // MARK: - Swap Panes

  @discardableResult
  mutating func swapPane(_ pane: MisttyPane, direction: NavigationDirection) -> MisttyPane? {
    guard let target = adjacentPane(from: pane, direction: direction) else { return nil }
    root = Self.swapLeaves(root, pane1: pane, pane2: target)
    return target
  }

  private static func swapLeaves(_ node: PaneLayoutNode, pane1: MisttyPane, pane2: MisttyPane)
    -> PaneLayoutNode
  {
    switch node {
    case .leaf(let p):
      if p.id == pane1.id { return .leaf(pane2) }
      if p.id == pane2.id { return .leaf(pane1) }
      return node
    case .empty:
      return node
    case .split(let dir, let a, let b, let ratio):
      return .split(
        dir, swapLeaves(a, pane1: pane1, pane2: pane2), swapLeaves(b, pane1: pane1, pane2: pane2),
        ratio)
    }
  }

  private static func firstLeaf(_ node: PaneLayoutNode) -> MisttyPane? {
    switch node {
    case .leaf(let p): return p
    case .empty: return nil
    case .split(_, let a, let b, _): return firstLeaf(a) ?? firstLeaf(b)
    }
  }

  private static func lastLeaf(_ node: PaneLayoutNode) -> MisttyPane? {
    switch node {
    case .leaf(let p): return p
    case .empty: return nil
    case .split(_, let a, let b, _): return lastLeaf(b) ?? lastLeaf(a)
    }
  }
}
