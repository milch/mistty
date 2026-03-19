import XCTest

@testable import Mistty

@MainActor
final class LayoutEngineTests: XCTestCase {
  private var nextPaneId = 1

  private func makePane() -> MisttyPane {
    let pane = MisttyPane(id: nextPaneId)
    nextPaneId += 1
    return pane
  }

  private func makePanes(_ count: Int) -> [MisttyPane] {
    (0..<count).map { _ in makePane() }
  }

  override func setUp() async throws {
    await MainActor.run { nextPaneId = 1 }
  }

  // MARK: - Even Horizontal

  func test_evenHorizontal_twoPanes() {
    let panes = makePanes(2)
    let node = LayoutEngine.apply(.evenHorizontal, to: panes)
    if case .split(.horizontal, .leaf(let a), .leaf(let b), let ratio) = node {
      XCTAssertEqual(a.id, panes[0].id)
      XCTAssertEqual(b.id, panes[1].id)
      XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    } else {
      XCTFail("Expected horizontal split of two leaves")
    }
  }

  func test_evenHorizontal_threePanes() {
    let panes = makePanes(3)
    let node = LayoutEngine.apply(.evenHorizontal, to: panes)
    if case .split(
      .horizontal, .leaf(let a), .split(.horizontal, .leaf(let b), .leaf(let c), let innerRatio),
      let outerRatio) = node
    {
      XCTAssertEqual(a.id, panes[0].id)
      XCTAssertEqual(b.id, panes[1].id)
      XCTAssertEqual(c.id, panes[2].id)
      XCTAssertEqual(outerRatio, 1.0 / 3.0, accuracy: 0.001)
      XCTAssertEqual(innerRatio, 0.5, accuracy: 0.001)
    } else {
      XCTFail("Expected nested horizontal splits")
    }
  }

  func test_evenHorizontal_fourPanes() {
    let panes = makePanes(4)
    let node = LayoutEngine.apply(.evenHorizontal, to: panes)
    let layout = PaneLayout(root: node)
    XCTAssertEqual(layout.leaves.count, 4)
    XCTAssertEqual(layout.leaves.map(\.id), panes.map(\.id))
  }

  // MARK: - Even Vertical

  func test_evenVertical_twoPanes() {
    let panes = makePanes(2)
    let node = LayoutEngine.apply(.evenVertical, to: panes)
    if case .split(.vertical, .leaf(let a), .leaf(let b), let ratio) = node {
      XCTAssertEqual(a.id, panes[0].id)
      XCTAssertEqual(b.id, panes[1].id)
      XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    } else {
      XCTFail("Expected vertical split of two leaves")
    }
  }

  func test_evenVertical_threePanes() {
    let panes = makePanes(3)
    let node = LayoutEngine.apply(.evenVertical, to: panes)
    if case .split(.vertical, .leaf(let a), .split(.vertical, _, _, _), let outerRatio) = node {
      XCTAssertEqual(a.id, panes[0].id)
      XCTAssertEqual(outerRatio, 1.0 / 3.0, accuracy: 0.001)
    } else {
      XCTFail("Expected nested vertical splits")
    }
  }

  // MARK: - Main Horizontal

  func test_mainHorizontal_twoPanes() {
    let panes = makePanes(2)
    let node = LayoutEngine.apply(.mainHorizontal, to: panes)
    if case .split(.horizontal, .leaf(let main), .leaf(let other), let ratio) = node {
      XCTAssertEqual(main.id, panes[0].id)
      XCTAssertEqual(other.id, panes[1].id)
      XCTAssertEqual(ratio, 0.66, accuracy: 0.001)
    } else {
      XCTFail("Expected horizontal split with 0.66 ratio")
    }
  }

  func test_mainHorizontal_threePanes() {
    let panes = makePanes(3)
    let node = LayoutEngine.apply(.mainHorizontal, to: panes)
    if case .split(.horizontal, .leaf(let main), .split(.vertical, _, _, _), let ratio) = node {
      XCTAssertEqual(main.id, panes[0].id)
      XCTAssertEqual(ratio, 0.66, accuracy: 0.001)
    } else {
      XCTFail("Expected main-horizontal layout")
    }
  }

  func test_mainHorizontal_fivePanes() {
    let panes = makePanes(5)
    let node = LayoutEngine.apply(.mainHorizontal, to: panes)
    let layout = PaneLayout(root: node)
    XCTAssertEqual(layout.leaves.count, 5)
    XCTAssertEqual(layout.leaves.map(\.id), panes.map(\.id))
  }

  // MARK: - Main Vertical

  func test_mainVertical_twoPanes() {
    let panes = makePanes(2)
    let node = LayoutEngine.apply(.mainVertical, to: panes)
    if case .split(.vertical, .leaf(let main), .leaf(let other), let ratio) = node {
      XCTAssertEqual(main.id, panes[0].id)
      XCTAssertEqual(other.id, panes[1].id)
      XCTAssertEqual(ratio, 0.66, accuracy: 0.001)
    } else {
      XCTFail("Expected vertical split with 0.66 ratio")
    }
  }

  func test_mainVertical_threePanes() {
    let panes = makePanes(3)
    let node = LayoutEngine.apply(.mainVertical, to: panes)
    if case .split(.vertical, .leaf(let main), .split(.horizontal, _, _, _), let ratio) = node {
      XCTAssertEqual(main.id, panes[0].id)
      XCTAssertEqual(ratio, 0.66, accuracy: 0.001)
    } else {
      XCTFail("Expected main-vertical layout")
    }
  }

  // MARK: - Tiled

  func test_tiled_twoPanes() {
    let panes = makePanes(2)
    let node = LayoutEngine.apply(.tiled, to: panes)
    if case .split(.horizontal, .leaf(let a), .leaf(let b), let ratio) = node {
      XCTAssertEqual(a.id, panes[0].id)
      XCTAssertEqual(b.id, panes[1].id)
      XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    } else {
      XCTFail("Expected simple horizontal split for 2-pane tiled")
    }
  }

  func test_tiled_threePanes() {
    let panes = makePanes(3)
    let node = LayoutEngine.apply(.tiled, to: panes)
    let layout = PaneLayout(root: node)
    XCTAssertEqual(layout.leaves.count, 3)
    XCTAssertEqual(layout.leaves.map(\.id), panes.map(\.id))

    if case .split(
      .vertical,
      .split(.horizontal, .leaf(let a), .leaf(let b), _),
      .split(.horizontal, .leaf(let c), .empty, _),
      let ratio) = node
    {
      XCTAssertEqual(a.id, panes[0].id)
      XCTAssertEqual(b.id, panes[1].id)
      XCTAssertEqual(c.id, panes[2].id)
      XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    } else {
      XCTFail("Expected 2x2 tiled grid with empty cell")
    }
  }

  func test_tiled_fourPanes() {
    let panes = makePanes(4)
    let node = LayoutEngine.apply(.tiled, to: panes)
    if case .split(
      .vertical,
      .split(.horizontal, .leaf(let a), .leaf(let b), _),
      .split(.horizontal, .leaf(let c), .leaf(let d), _),
      _) = node
    {
      XCTAssertEqual(a.id, panes[0].id)
      XCTAssertEqual(b.id, panes[1].id)
      XCTAssertEqual(c.id, panes[2].id)
      XCTAssertEqual(d.id, panes[3].id)
    } else {
      XCTFail("Expected 2x2 tiled grid")
    }
  }

  func test_tiled_fivePanes() {
    let panes = makePanes(5)
    let node = LayoutEngine.apply(.tiled, to: panes)
    let layout = PaneLayout(root: node)
    XCTAssertEqual(layout.leaves.count, 5)
    XCTAssertEqual(layout.leaves.map(\.id), panes.map(\.id))
  }

  // MARK: - Edge cases

  func test_singlePaneReturnsLeaf() {
    let panes = makePanes(1)
    let node = LayoutEngine.apply(.evenHorizontal, to: panes)
    if case .leaf(let p) = node {
      XCTAssertEqual(p.id, panes[0].id)
    } else {
      XCTFail("Single pane should return a leaf node")
    }
  }

  func test_emptyPanesReturnsEmpty() {
    let node = LayoutEngine.apply(.evenHorizontal, to: [])
    if case .empty = node {
      // pass
    } else {
      XCTFail("Expected .empty for empty panes array")
    }
  }
}
