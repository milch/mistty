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

  /// Find the nearest adjacent pane in `direction` using the actual layout
  /// geometry. Computes each leaf's unit rect (within [0, 1]), filters to
  /// panes on the correct side, and picks the one closest to the source —
  /// ties on movement-axis distance are broken by orthogonal-axis center
  /// alignment so navigation stays in the same row/column.
  func adjacentPane(from pane: MisttyPane, direction: NavigationDirection) -> MisttyPane? {
    let rects = Self.collectRects(root, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let source = rects[pane.id] else { return nil }

    let eps: CGFloat = 1e-4
    var best: (pane: MisttyPane, movement: CGFloat, orthogonal: CGFloat)?
    for leaf in leaves where leaf.id != pane.id {
      guard let r = rects[leaf.id] else { continue }
      let movement: CGFloat
      let orthogonal: CGFloat
      switch direction {
      case .left:
        guard r.maxX <= source.minX + eps else { continue }
        movement = source.minX - r.maxX
        orthogonal = abs(r.midY - source.midY)
      case .right:
        guard r.minX >= source.maxX - eps else { continue }
        movement = r.minX - source.maxX
        orthogonal = abs(r.midY - source.midY)
      case .up:
        guard r.maxY <= source.minY + eps else { continue }
        movement = source.minY - r.maxY
        orthogonal = abs(r.midX - source.midX)
      case .down:
        guard r.minY >= source.maxY - eps else { continue }
        movement = r.minY - source.maxY
        orthogonal = abs(r.midX - source.midX)
      }
      if let current = best {
        if movement < current.movement
          || (abs(movement - current.movement) < eps && orthogonal < current.orthogonal)
        {
          best = (leaf, movement, orthogonal)
        }
      } else {
        best = (leaf, movement, orthogonal)
      }
    }
    return best?.pane
  }

  private static func collectRects(_ node: PaneLayoutNode, in bounds: CGRect) -> [Int: CGRect] {
    switch node {
    case .leaf(let p):
      return [p.id: bounds]
    case .empty:
      return [:]
    case .split(let dir, let a, let b, let ratio):
      let aBounds: CGRect
      let bBounds: CGRect
      switch dir {
      case .horizontal:
        let w = bounds.width * ratio
        aBounds = CGRect(x: bounds.minX, y: bounds.minY, width: w, height: bounds.height)
        bBounds = CGRect(
          x: bounds.minX + w, y: bounds.minY, width: bounds.width - w, height: bounds.height)
      case .vertical:
        let h = bounds.height * ratio
        aBounds = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: h)
        bBounds = CGRect(
          x: bounds.minX, y: bounds.minY + h, width: bounds.width, height: bounds.height - h)
      }
      var result = collectRects(a, in: aBounds)
      for (k, v) in collectRects(b, in: bBounds) { result[k] = v }
      return result
    }
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

}
