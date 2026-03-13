import XCTest
@testable import Mistty

@MainActor
final class PaneLayoutTests: XCTestCase {
    func test_singlePaneHasOneLeaf() {
        let pane = MisttyPane()
        let layout = PaneLayout(pane: pane)
        XCTAssertEqual(layout.leaves.count, 1)
        XCTAssertEqual(layout.leaves[0].id, pane.id)
    }

    func test_splitAddsSecondLeaf() {
        let pane = MisttyPane()
        var layout = PaneLayout(pane: pane)
        layout.split(pane: pane, direction: .horizontal)
        XCTAssertEqual(layout.leaves.count, 2)
    }

    func test_splitPreservesOriginalPane() {
        let pane = MisttyPane()
        var layout = PaneLayout(pane: pane)
        layout.split(pane: pane, direction: .horizontal)
        XCTAssertTrue(layout.leaves.contains(where: { $0.id == pane.id }))
    }

    func test_splitDirectionIsRecorded() {
        let pane = MisttyPane()
        var layout = PaneLayout(pane: pane)
        layout.split(pane: pane, direction: .vertical)
        if case .split(let dir, _, _, _) = layout.root {
            XCTAssertEqual(dir, .vertical)
        } else {
            XCTFail("Expected split at root")
        }
    }

    func test_nestedSplit() {
        let pane = MisttyPane()
        var layout = PaneLayout(pane: pane)
        layout.split(pane: pane, direction: .horizontal)
        let secondPane = layout.leaves.first(where: { $0.id != pane.id })!
        layout.split(pane: secondPane, direction: .vertical)
        XCTAssertEqual(layout.leaves.count, 3)
    }

    func test_adjacentPaneHorizontal() {
        let pane1 = MisttyPane()
        var layout = PaneLayout(pane: pane1)
        layout.split(pane: pane1, direction: .horizontal)
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
        let pane1 = MisttyPane()
        var layout = PaneLayout(pane: pane1)
        layout.split(pane: pane1, direction: .vertical)
        let panes = layout.leaves

        let down = layout.adjacentPane(from: panes[0], direction: .down)
        XCTAssertEqual(down?.id, panes[1].id)

        let up = layout.adjacentPane(from: panes[1], direction: .up)
        XCTAssertEqual(up?.id, panes[0].id)
    }

    func test_splitRatio() {
        let pane1 = MisttyPane()
        var layout = PaneLayout(pane: pane1)
        layout.split(pane: pane1, direction: .horizontal)
        if case .split(_, _, _, let ratio) = layout.root {
            XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Expected split node")
        }
    }

    func test_resizeSplit() {
        let pane1 = MisttyPane()
        var layout = PaneLayout(pane: pane1)
        layout.split(pane: pane1, direction: .horizontal)
        let panes = layout.leaves
        layout.resizeSplit(containing: panes[0], delta: 0.1)
        if case .split(_, _, _, let ratio) = layout.root {
            XCTAssertEqual(ratio, 0.6, accuracy: 0.001)
        } else {
            XCTFail("Expected split node")
        }
    }

    func test_rotateSplit() {
        let pane1 = MisttyPane()
        var layout = PaneLayout(pane: pane1)
        layout.split(pane: pane1, direction: .horizontal)
        layout.rotateDirection(containing: pane1)
        if case .split(let dir, _, _, _) = layout.root {
            XCTAssertEqual(dir, .vertical)
        } else {
            XCTFail("Expected split")
        }
    }

    func test_tabIntegration_splitUpdatesLayout() {
        let tab = MisttyTab()
        XCTAssertEqual(tab.layout.leaves.count, 1)
        tab.splitActivePane(direction: .horizontal)
        XCTAssertEqual(tab.layout.leaves.count, 2)
        XCTAssertEqual(tab.panes.count, 2)
    }
}
