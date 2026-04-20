import XCTest

@testable import Mistty

@MainActor
final class PaneLayoutTests: XCTestCase {
  private var nextPaneId = 1

  private func makePane() -> MisttyPane {
    let pane = MisttyPane(id: nextPaneId)
    nextPaneId += 1
    return pane
  }

  override func setUp() async throws {
    await MainActor.run {
      nextPaneId = 1
    }
  }

  func test_singlePaneHasOneLeaf() {
    let pane = makePane()
    let layout = PaneLayout(pane: pane)
    XCTAssertEqual(layout.leaves.count, 1)
    XCTAssertEqual(layout.leaves[0].id, pane.id)
  }

  func test_splitAddsSecondLeaf() {
    let pane = makePane()
    var layout = PaneLayout(pane: pane)
    layout.split(pane: pane, direction: .horizontal, newPane: makePane())
    XCTAssertEqual(layout.leaves.count, 2)
  }

  func test_splitPreservesOriginalPane() {
    let pane = makePane()
    var layout = PaneLayout(pane: pane)
    layout.split(pane: pane, direction: .horizontal, newPane: makePane())
    XCTAssertTrue(layout.leaves.contains(where: { $0.id == pane.id }))
  }

  func test_splitDirectionIsRecorded() {
    let pane = makePane()
    var layout = PaneLayout(pane: pane)
    layout.split(pane: pane, direction: .vertical, newPane: makePane())
    if case .split(let dir, _, _, _) = layout.root {
      XCTAssertEqual(dir, .vertical)
    } else {
      XCTFail("Expected split at root")
    }
  }

  func test_nestedSplit() {
    let pane = makePane()
    var layout = PaneLayout(pane: pane)
    layout.split(pane: pane, direction: .horizontal, newPane: makePane())
    let secondPane = layout.leaves.first(where: { $0.id != pane.id })!
    layout.split(pane: secondPane, direction: .vertical, newPane: makePane())
    XCTAssertEqual(layout.leaves.count, 3)
  }

  func test_adjacentPaneHorizontal() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal, newPane: makePane())
    let panes = layout.leaves

    // Right of first pane should be second pane
    let right = layout.adjacentPane(from: panes[0], direction: .right)
    XCTAssertEqual(right?.id, panes[1].id)

    // Left of second pane should be first pane
    let left = layout.adjacentPane(from: panes[1], direction: .left)
    XCTAssertEqual(left?.id, panes[0].id)

    // Left of first pane should be nil (edge)
    let none = layout.adjacentPane(from: panes[0], direction: .left)
    XCTAssertNil(none)
  }

  func test_adjacentPaneVertical() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .vertical, newPane: makePane())
    let panes = layout.leaves

    let down = layout.adjacentPane(from: panes[0], direction: .down)
    XCTAssertEqual(down?.id, panes[1].id)

    let up = layout.adjacentPane(from: panes[1], direction: .up)
    XCTAssertEqual(up?.id, panes[0].id)
  }

  func test_splitRatio() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal, newPane: makePane())
    if case .split(_, _, _, let ratio) = layout.root {
      XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    } else {
      XCTFail("Expected split node")
    }
  }

  func test_resizeSplit() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal, newPane: makePane())
    let panes = layout.leaves
    layout.resizeSplit(containing: panes[0], delta: 0.1)
    if case .split(_, _, _, let ratio) = layout.root {
      XCTAssertEqual(ratio, 0.6, accuracy: 0.001)
    } else {
      XCTFail("Expected split node")
    }
  }

  func test_rotateSplit() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal, newPane: makePane())
    layout.rotateDirection(containing: pane1)
    if case .split(let dir, _, _, _) = layout.root {
      XCTAssertEqual(dir, .vertical)
    } else {
      XCTFail("Expected split")
    }
  }

  func test_resizeSplitCells_horizontal() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal, newPane: makePane())
    let panes = layout.leaves
    // 800 px tab, 10 px/cell → 80 cols; 5 cells → 5*10/800 = 0.0625 delta.
    layout.resizeSplit(
      containing: panes[0], cells: 5, along: .horizontal, cellSize: 10, tabSize: 800)
    if case .split(_, _, _, let ratio) = layout.root {
      XCTAssertEqual(ratio, 0.5 + 0.0625, accuracy: 0.0001)
    } else {
      XCTFail("Expected split")
    }
  }

  func test_resizeSplitCells_negativeShrinks() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal, newPane: makePane())
    let panes = layout.leaves
    layout.resizeSplit(
      containing: panes[0], cells: -1, along: .horizontal, cellSize: 8, tabSize: 800)
    // -1 cell * 8 px / 800 px = -0.01 delta
    if case .split(_, _, _, let ratio) = layout.root {
      XCTAssertEqual(ratio, 0.49, accuracy: 0.0001)
    } else {
      XCTFail("Expected split")
    }
  }

  func test_resizeSplitCells_vertical() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .vertical, newPane: makePane())
    let panes = layout.leaves
    // 480 px tab, 20 px/cell (24 rows); 3 cells → 3*20/480 = 0.125
    layout.resizeSplit(
      containing: panes[0], cells: 3, along: .vertical, cellSize: 20, tabSize: 480)
    if case .split(_, _, _, let ratio) = layout.root {
      XCTAssertEqual(ratio, 0.625, accuracy: 0.0001)
    } else {
      XCTFail("Expected split")
    }
  }

  /// When the target split is nested, its container is smaller than the full
  /// tab — container pixel size must be `tabSize * containerUnit`. Layout:
  ///  [ A | ( B on top, C on bottom ) ] with outer ratio 0.5 (horizontal).
  /// Adjusting the inner vertical split (containing C) with cells=2,
  /// cellSize=10, tabSize=400 should compute container height = 400 (full
  /// height), delta = 2*10/400 = 0.05. Container for the vertical inner
  /// split is the right half of the tab, whose height is still the full tab
  /// height, so delta = 0.05.
  func test_resizeSplitCells_nested_usesSplitContainer() {
    let pA = makePane()
    let pB = makePane()
    let pC = makePane()
    let root: PaneLayoutNode = .split(
      .horizontal,
      .leaf(pA),
      .split(.vertical, .leaf(pB), .leaf(pC), 0.5),
      0.5)
    var layout = PaneLayout(root: root)
    layout.resizeSplit(
      containing: pC, cells: 2, along: .vertical, cellSize: 10, tabSize: 400)
    // Walk: outer horizontal split doesn't match vertical direction; recurse
    // into right subtree. The inner vertical split's container has width
    // 0.5 * tab, height 1.0 * tab = 400 px → delta = 2*10/400 = 0.05.
    if case .split(.horizontal, _, let right, _) = layout.root,
      case .split(.vertical, _, _, let r) = right
    {
      XCTAssertEqual(r, 0.55, accuracy: 0.0001)
    } else {
      XCTFail("Expected nested split")
    }
  }

  /// Conversely, when the split container shrinks along the movement axis
  /// (nested split inside the smaller side of an outer split along the same
  /// axis as the movement), the ratio delta should scale up accordingly.
  /// Layout: vertical split at root with ratio 0.25 (top band); the top side
  /// is itself a vertical split with two panes. Adjusting the inner vertical
  /// split with cells=1, cellSize=10, tabSize=400 → inner container height
  /// = 0.25 * 400 = 100 px → delta = 1*10/100 = 0.10.
  func test_resizeSplitCells_nestedSameAxis_scalesByContainerSize() {
    let pA = makePane()
    let pB = makePane()
    let pC = makePane()
    // Inner vertical split (A over B), then outer vertical split putting
    // that on top with a small top band (ratio 0.25).
    let root: PaneLayoutNode = .split(
      .vertical,
      .split(.vertical, .leaf(pA), .leaf(pB), 0.5),
      .leaf(pC),
      0.25)
    var layout = PaneLayout(root: root)
    // Target pane A. The outer vertical split matches direction first and
    // would normally get adjusted — but A is only in the top subtree, so
    // `targetSplitContainer` returns the outer split (matching direction at
    // the first ancestor). Container height = full tab = 400. delta = 0.025.
    layout.resizeSplit(
      containing: pA, cells: 1, along: .vertical, cellSize: 10, tabSize: 400)
    if case .split(.vertical, _, _, let r) = layout.root {
      XCTAssertEqual(r, 0.275, accuracy: 0.0001)
    } else {
      XCTFail("Expected vertical split")
    }
  }

  func test_resizeSplitCells_zeroCellsIsNoop() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal, newPane: makePane())
    let panes = layout.leaves
    layout.resizeSplit(
      containing: panes[0], cells: 0, along: .horizontal, cellSize: 10, tabSize: 800)
    if case .split(_, _, _, let ratio) = layout.root {
      XCTAssertEqual(ratio, 0.5, accuracy: 0.0001)
    }
  }

  func test_unitRect_singlePane_isFullBounds() {
    let p = makePane()
    let layout = PaneLayout(pane: p)
    let r = layout.unitRect(of: p)
    XCTAssertEqual(r?.width, 1.0)
    XCTAssertEqual(r?.height, 1.0)
  }

  func test_unitRect_horizontalSplit_halfWidths() {
    let p1 = makePane()
    var layout = PaneLayout(pane: p1)
    layout.split(pane: p1, direction: .horizontal, newPane: makePane())
    let panes = layout.leaves
    let r0 = layout.unitRect(of: panes[0])
    let r1 = layout.unitRect(of: panes[1])
    XCTAssertEqual(r0?.width ?? 0, 0.5, accuracy: 0.001)
    XCTAssertEqual(r1?.width ?? 0, 0.5, accuracy: 0.001)
    XCTAssertEqual(r0?.height ?? 0, 1.0, accuracy: 0.001)
  }

  func test_resizeSplitDirectionAware() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .vertical, newPane: makePane())
    let panes = layout.leaves

    // Get initial ratio
    let ratioBefore: CGFloat
    if case .split(_, _, _, let r) = layout.root { ratioBefore = r } else { return XCTFail() }

    // Resizing a vertical split with horizontal direction should be a no-op
    layout.resizeSplit(containing: panes[0], delta: 0.1, along: .horizontal)
    if case .split(_, _, _, let r) = layout.root {
      XCTAssertEqual(r, ratioBefore, accuracy: 0.001)
    }

    // Resizing along matching direction should work
    layout.resizeSplit(containing: panes[0], delta: 0.1, along: .vertical)
    if case .split(_, _, _, let r) = layout.root {
      XCTAssertEqual(r, 0.6, accuracy: 0.001)
    }
  }

  func test_removePaneFromTwoPaneSplit() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal, newPane: makePane())
    let panes = layout.leaves
    XCTAssertEqual(panes.count, 2)

    layout.remove(pane: panes[1])
    XCTAssertEqual(layout.leaves.count, 1)
    XCTAssertEqual(layout.leaves[0].id, pane1.id)
    XCTAssertFalse(layout.isEmpty)
  }

  func test_removeLastPane() {
    let pane1 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.remove(pane: pane1)
    XCTAssertTrue(layout.isEmpty)
    XCTAssertTrue(layout.leaves.isEmpty)
  }

  func test_removeNonExistentPane() {
    let pane1 = makePane()
    let pane2 = makePane()
    var layout = PaneLayout(pane: pane1)
    layout.remove(pane: pane2)
    XCTAssertEqual(layout.leaves.count, 1)
    XCTAssertFalse(layout.isEmpty)
  }

  // MARK: - Empty node handling

  func test_leavesSkipsEmpty() {
    let pane = makePane()
    let root: PaneLayoutNode = .split(.horizontal, .leaf(pane), .empty, 0.5)
    let layout = PaneLayout(root: root)
    XCTAssertEqual(layout.leaves.count, 1)
    XCTAssertEqual(layout.leaves[0].id, pane.id)
  }

  func test_rootInitializer() {
    let pane = makePane()
    let root: PaneLayoutNode = .leaf(pane)
    let layout = PaneLayout(root: root)
    XCTAssertEqual(layout.leaves.count, 1)
  }

  func test_adjacentPaneSkipsEmpty() {
    let pane1 = makePane()
    let pane2 = makePane()
    let root: PaneLayoutNode = .split(
      .horizontal,
      .leaf(pane1),
      .split(.horizontal, .empty, .leaf(pane2), 0.5),
      0.5)
    let layout = PaneLayout(root: root)
    let adjacent = layout.adjacentPane(from: pane1, direction: .right)
    XCTAssertEqual(adjacent?.id, pane2.id)
  }

  func test_removeCollapsesSiblingEmpty() {
    let pane1 = makePane()
    let pane2 = makePane()
    let pane3 = makePane()
    let root: PaneLayoutNode = .split(
      .vertical,
      .split(.horizontal, .leaf(pane1), .leaf(pane2), 0.5),
      .split(.horizontal, .leaf(pane3), .empty, 0.5),
      0.5)
    var layout = PaneLayout(root: root)
    layout.remove(pane: pane3)
    XCTAssertEqual(layout.leaves.count, 2)
    if case .split(.horizontal, .leaf(let a), .leaf(let b), _) = layout.root {
      XCTAssertEqual(a.id, pane1.id)
      XCTAssertEqual(b.id, pane2.id)
    } else {
      XCTFail("Expected flat horizontal split after collapsing empty sibling")
    }
  }

  func test_firstLeafSkipsEmpty() {
    let pane = makePane()
    let root: PaneLayoutNode = .split(.horizontal, .empty, .leaf(pane), 0.5)
    let layout = PaneLayout(root: root)
    let adjacent = layout.adjacentPane(from: pane, direction: .left)
    XCTAssertNil(adjacent)
  }

  func test_swapPaneSkipsEmpty() {
    let pane1 = makePane()
    let root: PaneLayoutNode = .split(.horizontal, .leaf(pane1), .empty, 0.5)
    var layout = PaneLayout(root: root)
    let target = layout.swapPane(pane1, direction: .right)
    XCTAssertNil(target)
  }

  // MARK: - 2x2 navigation

  /// Build the classic 2x2 grid by splitting pane1 horizontally, then
  /// splitting each side vertically. Returns panes in the order [1, 2, 3, 4]
  /// where visual position is:
  ///   1 | 2
  ///   --+--
  ///   3 | 4
  private func make2x2() -> (PaneLayout, MisttyPane, MisttyPane, MisttyPane, MisttyPane) {
    let p1 = makePane()
    var layout = PaneLayout(pane: p1)
    let p2 = makePane()
    layout.split(pane: p1, direction: .horizontal, newPane: p2)
    let p3 = makePane()
    layout.split(pane: p1, direction: .vertical, newPane: p3)
    let p4 = makePane()
    layout.split(pane: p2, direction: .vertical, newPane: p4)
    return (layout, p1, p2, p3, p4)
  }

  func test_2x2_horizontalNavStaysOnSameRow_top() {
    let (layout, p1, p2, _, _) = make2x2()
    XCTAssertEqual(layout.adjacentPane(from: p1, direction: .right)?.id, p2.id)
    XCTAssertEqual(layout.adjacentPane(from: p2, direction: .left)?.id, p1.id)
  }

  func test_2x2_horizontalNavStaysOnSameRow_bottom() {
    let (layout, _, _, p3, p4) = make2x2()
    XCTAssertEqual(layout.adjacentPane(from: p3, direction: .right)?.id, p4.id)
    XCTAssertEqual(layout.adjacentPane(from: p4, direction: .left)?.id, p3.id)
  }

  func test_2x2_verticalNavStaysOnSameColumn_left() {
    let (layout, p1, _, p3, _) = make2x2()
    XCTAssertEqual(layout.adjacentPane(from: p1, direction: .down)?.id, p3.id)
    XCTAssertEqual(layout.adjacentPane(from: p3, direction: .up)?.id, p1.id)
  }

  func test_2x2_verticalNavStaysOnSameColumn_right() {
    let (layout, _, p2, _, p4) = make2x2()
    XCTAssertEqual(layout.adjacentPane(from: p2, direction: .down)?.id, p4.id)
    XCTAssertEqual(layout.adjacentPane(from: p4, direction: .up)?.id, p2.id)
  }

  func test_2x2_edgeReturnsNil() {
    let (layout, p1, p2, p3, p4) = make2x2()
    XCTAssertNil(layout.adjacentPane(from: p1, direction: .left))
    XCTAssertNil(layout.adjacentPane(from: p1, direction: .up))
    XCTAssertNil(layout.adjacentPane(from: p2, direction: .right))
    XCTAssertNil(layout.adjacentPane(from: p2, direction: .up))
    XCTAssertNil(layout.adjacentPane(from: p3, direction: .left))
    XCTAssertNil(layout.adjacentPane(from: p3, direction: .down))
    XCTAssertNil(layout.adjacentPane(from: p4, direction: .right))
    XCTAssertNil(layout.adjacentPane(from: p4, direction: .down))
  }

  /// Tall pane on the left, two stacked on the right:
  ///     | B
  ///  A  +--
  ///     | C
  func test_tallLeftTwoRight_rightFromTall() {
    let pA = makePane()
    let pB = makePane()
    let pC = makePane()
    // Build: horizontal(leaf(A), vertical(leaf(B), leaf(C)))
    let root: PaneLayoutNode = .split(
      .horizontal,
      .leaf(pA),
      .split(.vertical, .leaf(pB), .leaf(pC), 0.5),
      0.5)
    let layout = PaneLayout(root: root)

    // From B, left → A (only pane on the left)
    XCTAssertEqual(layout.adjacentPane(from: pB, direction: .left)?.id, pA.id)
    XCTAssertEqual(layout.adjacentPane(from: pC, direction: .left)?.id, pA.id)
    // From A, right → tie between B and C (centers equidistant); any non-nil is acceptable
    let rightFromA = layout.adjacentPane(from: pA, direction: .right)
    XCTAssertTrue(rightFromA?.id == pB.id || rightFromA?.id == pC.id)
  }

  // MARK: - Tab integration

  func test_tabIntegration_splitUpdatesLayout() {
    let store = SessionStore()
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertEqual(tab.layout.leaves.count, 1)
    tab.splitActivePane(direction: .horizontal)
    XCTAssertEqual(tab.layout.leaves.count, 2)
    XCTAssertEqual(tab.panes.count, 2)
  }

  /// Splitting inside a nested subtree: starting layout
  ///   1 | 2
  ///     +---
  ///     | 3
  /// Splitting pane 1 vertically adds pane 4 below it. The new pane must
  /// become active — NOT "the last leaf in traversal order" (which would
  /// incorrectly resolve to pane 3 here).
  func test_tabIntegration_splitInNestedSubtreeFocusesNewPane() {
    let store = SessionStore()
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)  // 1 | 2  (active=2)
    tab.splitActivePane(direction: .vertical)  // 1 | 2/3 (active=3)
    tab.activePane = tab.panes.first  // focus pane 1
    let leafIdsBefore = Set(tab.layout.leaves.map { $0.id })
    tab.splitActivePane(direction: .vertical)  // 1/4 | 2/3 — new pane 4 below 1
    let leafIdsAfter = Set(tab.layout.leaves.map { $0.id })
    let newPaneId = leafIdsAfter.subtracting(leafIdsBefore).first
    XCTAssertNotNil(newPaneId)
    XCTAssertEqual(tab.activePane?.id, newPaneId)
  }
}
