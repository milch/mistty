import Foundation

enum NavigationDirection {
  case left, right, up, down
}

/// Layout tree describing the split-and-pane shape of a tab. Leaves
/// reference panes by **ID**, not by class instance — the owning
/// `MisttyTab` holds the panes themselves via `tab.panes`. Without
/// this indirection, every cached SwiftUI view tree (e.g. `PaneLayoutView`
/// in `ForEachState.Item`) ended up retaining the closed pane via the
/// indirect-enum heap allocation of `.leaf(pane)`, leaking the libghostty
/// surface forever.
indirect enum PaneLayoutNode {
  case leaf(Int)
  case empty
  case split(SplitDirection, PaneLayoutNode, PaneLayoutNode, CGFloat)
}

@MainActor
struct PaneLayout {
  var root: PaneLayoutNode

  init(pane: MisttyPane) {
    root = .leaf(pane.id)
  }

  init(root: PaneLayoutNode) {
    self.root = root
  }

  /// Pane IDs in display (left-to-right, top-to-bottom) order. The owning
  /// `MisttyTab` is the source-of-truth for the actual `MisttyPane`
  /// instances; the layout just describes the arrangement.
  var leafIDs: [Int] {
    if isEmpty { return [] }
    return Self.collectLeafIDs(root)
  }

  private static func collectLeafIDs(_ node: PaneLayoutNode) -> [Int] {
    switch node {
    case .leaf(let id):
      return [id]
    case .empty:
      return []
    case .split(_, let a, let b, _):
      return collectLeafIDs(a) + collectLeafIDs(b)
    }
  }

  /// Returns true if the pane was removed. If removing the last pane,
  /// `leafIDs` will be empty — the caller should handle that (e.g. close the tab).
  @discardableResult
  mutating func remove(pane: MisttyPane) -> Bool {
    if let newRoot = Self.removeNode(root, target: pane.id) {
      root = newRoot
    } else {
      // Last pane removed — collapse to `.empty`. Setting only `isEmpty
      // = true` and leaving `root` at the old `.leaf(id)` value would
      // leave a stale node in the tree; harmless after the ID refactor
      // (the leaf no longer retains the pane) but still confusing.
      root = .empty
      isEmpty = true
    }
    return true
  }

  private(set) var isEmpty = false

  private static func removeNode(_ node: PaneLayoutNode, target: Int) -> PaneLayoutNode? {
    switch node {
    case .leaf(let id) where id == target:
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
        if case .empty = left { return right }
        if case .empty = right { return left }
        return .split(dir, left, right, ratio)
      }
    }
  }

  mutating func split(pane: MisttyPane, direction: SplitDirection, newPane: MisttyPane) {
    root = Self.insertSplit(root, target: pane.id, direction: direction, newPaneID: newPane.id)
  }

  private static func insertSplit(
    _ node: PaneLayoutNode,
    target: Int,
    direction: SplitDirection,
    newPaneID: Int
  ) -> PaneLayoutNode {
    switch node {
    case .leaf(let id) where id == target:
      return .split(direction, .leaf(id), .leaf(newPaneID), 0.5)
    case .leaf:
      return node
    case .empty:
      return node
    case .split(let dir, let a, let b, let ratio):
      return .split(
        dir,
        insertSplit(a, target: target, direction: direction, newPaneID: newPaneID),
        insertSplit(b, target: target, direction: direction, newPaneID: newPaneID),
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
      let isDirectChild: Bool
      switch (a, b) {
      case (.leaf(let id), _) where id == target: isDirectChild = true
      case (_, .leaf(let id)) where id == target: isDirectChild = true
      default: isDirectChild = false
      }

      if isDirectChild {
        return .split(dir.toggled, a, b, ratio)
      }

      return .split(dir, rotate(a, target: target), rotate(b, target: target), ratio)
    }
  }

  // MARK: - Resize

  mutating func resizeSplit(
    containing pane: MisttyPane, delta: CGFloat, along direction: SplitDirection? = nil
  ) {
    root = Self.adjustRatio(root, target: pane.id, delta: delta, along: direction)
  }

  /// Resize the split whose divider sits between two specific panes. Used by
  /// drag-to-resize where the divider's identity is unambiguous — we know
  /// exactly which split the user grabbed. Walks the tree to find the
  /// lowest ancestor that puts `aRep` and `bRep` on opposite sides, and
  /// bumps that split's ratio by `delta`.
  mutating func resizeSplit(
    between aRep: MisttyPane, and bRep: MisttyPane, delta: CGFloat
  ) {
    root = Self.adjustRatioBetween(root, a: aRep.id, b: bRep.id, delta: delta)
  }

  private static func adjustRatioBetween(
    _ node: PaneLayoutNode, a: Int, b: Int, delta: CGFloat
  ) -> PaneLayoutNode {
    switch node {
    case .leaf, .empty:
      return node
    case .split(let dir, let childA, let childB, let ratio):
      let aInA = collectLeafIDs(childA).contains(a)
      let aInB = collectLeafIDs(childB).contains(a)
      let bInA = collectLeafIDs(childA).contains(b)
      let bInB = collectLeafIDs(childB).contains(b)

      if (aInA && bInB) || (aInB && bInA) {
        return .split(dir, childA, childB, max(0.1, min(0.9, ratio + delta)))
      }

      if aInA && bInA {
        return .split(
          dir, adjustRatioBetween(childA, a: a, b: b, delta: delta), childB, ratio)
      }
      if aInB && bInB {
        return .split(
          dir, childA, adjustRatioBetween(childB, a: a, b: b, delta: delta), ratio)
      }
      return node
    }
  }

  mutating func resizeSplit(
    containing pane: MisttyPane,
    cells: Int,
    along direction: SplitDirection,
    cellSize: CGFloat,
    tabSize: CGFloat
  ) {
    guard cells != 0, cellSize > 0, tabSize > 0 else { return }
    guard
      let container = Self.targetSplitContainer(
        root, target: pane.id, along: direction,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1))
    else { return }
    let containerPx: CGFloat =
      direction == .horizontal ? container.width * tabSize : container.height * tabSize
    guard containerPx > 0 else { return }
    let delta = CGFloat(cells) * cellSize / containerPx
    root = Self.adjustRatio(root, target: pane.id, delta: delta, along: direction)
  }

  private static func targetSplitContainer(
    _ node: PaneLayoutNode,
    target: Int,
    along direction: SplitDirection,
    bounds: CGRect
  ) -> CGRect? {
    switch node {
    case .leaf, .empty:
      return nil
    case .split(let dir, let a, let b, let ratio):
      let aContains = collectLeafIDs(a).contains(target)
      let bContains = collectLeafIDs(b).contains(target)
      guard aContains || bContains else { return nil }
      if dir == direction {
        return bounds
      }
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
      if aContains {
        return targetSplitContainer(a, target: target, along: direction, bounds: aBounds)
      } else {
        return targetSplitContainer(b, target: target, along: direction, bounds: bBounds)
      }
    }
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
      let aContains = collectLeafIDs(a).contains(target)
      let bContains = collectLeafIDs(b).contains(target)
      guard aContains || bContains else { return node }

      if direction == nil || direction == dir {
        return .split(dir, a, b, max(0.1, min(0.9, ratio + delta)))
      }

      if aContains {
        return .split(dir, adjustRatio(a, target: target, delta: delta, along: direction), b, ratio)
      } else {
        return .split(dir, a, adjustRatio(b, target: target, delta: delta, along: direction), ratio)
      }
    }
  }

  // MARK: - Pane Navigation

  /// Unit rect of the given pane within the layout (coordinates in [0, 1]).
  func unitRect(of pane: MisttyPane) -> CGRect? {
    Self.collectRects(root, in: CGRect(x: 0, y: 0, width: 1, height: 1))[pane.id]
  }

  /// ID of the nearest adjacent pane in `direction` using the actual layout
  /// geometry. Returns the ID — callers resolve to `MisttyPane` via the
  /// owning tab's `panes` array.
  func adjacentPaneID(from pane: MisttyPane, direction: NavigationDirection) -> Int? {
    let rects = Self.collectRects(root, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let source = rects[pane.id] else { return nil }

    let eps: CGFloat = 1e-4
    var best: (id: Int, movement: CGFloat, orthogonal: CGFloat)?
    for leafID in leafIDs where leafID != pane.id {
      guard let r = rects[leafID] else { continue }
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
          best = (leafID, movement, orthogonal)
        }
      } else {
        best = (leafID, movement, orthogonal)
      }
    }
    return best?.id
  }

  private static func collectRects(_ node: PaneLayoutNode, in bounds: CGRect) -> [Int: CGRect] {
    switch node {
    case .leaf(let id):
      return [id: bounds]
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

  /// Swap `pane` with its neighbour in `direction`. Returns the ID of the
  /// pane that was swapped with, or `nil` if there's no neighbour.
  @discardableResult
  mutating func swapPane(_ pane: MisttyPane, direction: NavigationDirection) -> Int? {
    guard let targetID = adjacentPaneID(from: pane, direction: direction) else { return nil }
    root = Self.swapLeafIDs(root, idA: pane.id, idB: targetID)
    return targetID
  }

  private static func swapLeafIDs(_ node: PaneLayoutNode, idA: Int, idB: Int) -> PaneLayoutNode {
    switch node {
    case .leaf(let id):
      if id == idA { return .leaf(idB) }
      if id == idB { return .leaf(idA) }
      return node
    case .empty:
      return node
    case .split(let dir, let a, let b, let ratio):
      return .split(
        dir, swapLeafIDs(a, idA: idA, idB: idB), swapLeafIDs(b, idA: idA, idB: idB), ratio)
    }
  }
}

// MARK: - Convenience: resolve leaf IDs against a panes array

extension PaneLayout {
  /// Resolves `leafIDs` to `MisttyPane` instances in display order. The
  /// supplied `panes` array is the source of truth (typically
  /// `tab.panes`); leaves whose IDs no longer have a corresponding pane
  /// are silently dropped.
  func leaves(in panes: [MisttyPane]) -> [MisttyPane] {
    let byID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
    return leafIDs.compactMap { byID[$0] }
  }

  func adjacentPane(
    from pane: MisttyPane, direction: NavigationDirection, in panes: [MisttyPane]
  ) -> MisttyPane? {
    guard let id = adjacentPaneID(from: pane, direction: direction) else { return nil }
    return panes.first { $0.id == id }
  }
}
