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

  func test_tabIntegration_splitUpdatesLayout() {
    let store = SessionStore()
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertEqual(tab.layout.leaves.count, 1)
    tab.splitActivePane(direction: .horizontal)
    XCTAssertEqual(tab.layout.leaves.count, 2)
    XCTAssertEqual(tab.panes.count, 2)
  }
}
