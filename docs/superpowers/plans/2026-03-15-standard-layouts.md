# Standard Layouts Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add number key shortcuts (1-5) in window mode to apply standard pane layouts (even-horizontal, even-vertical, main-horizontal, main-vertical, tiled).

**Architecture:** New `LayoutEngine` struct builds `PaneLayoutNode` trees from a list of panes. `PaneLayoutNode` gains a `.empty` case for tiled grid padding. `MisttyTab` gets `applyStandardLayout()` which extracts leaves, calls `LayoutEngine`, and replaces the layout tree.

**Tech Stack:** Swift 6, SwiftUI, XCTest

**Spec:** `docs/superpowers/specs/2026-03-14-standard-layouts-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Mistty/Models/PaneLayout.swift` | Modify | Add `.empty` case, `init(root:)`, update all switch statements |
| `Mistty/Models/LayoutEngine.swift` | Create | `StandardLayout` enum + `LayoutEngine` struct with 5 layout builders |
| `Mistty/Models/MisttyTab.swift` | Modify | Add `applyStandardLayout()` method |
| `Mistty/Views/Terminal/PaneLayoutView.swift` | Modify | Render `.empty` case |
| `Mistty/Views/Terminal/WindowModeHints.swift` | Modify | Add `1-5: layouts` hint |
| `Mistty/App/ContentView.swift` | Modify | Handle keyCodes 18-21,23 in window mode |
| `MisttyTests/Models/LayoutEngineTests.swift` | Create | Tests for all 5 layouts |
| `MisttyTests/Models/PaneLayoutTests.swift` | Modify | Tests for `.empty` handling in existing operations |

---

## Task 1: Add `.empty` case to `PaneLayoutNode` and update `PaneLayout`

**Files:**
- Modify: `Mistty/Models/PaneLayout.swift`
- Modify: `MisttyTests/Models/PaneLayoutTests.swift`

- [ ] **Step 1: Write failing tests for `.empty` handling**

Add to `MisttyTests/Models/PaneLayoutTests.swift`:

```swift
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
    // Layout: split(.h, pane1, split(.h, .empty, pane2, 0.5), 0.5)
    // Adjacent right of pane1 should skip .empty and find pane2
    let root: PaneLayoutNode = .split(.horizontal,
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
    // Layout: split(.v, split(.h, pane1, pane2, 0.5), split(.h, pane3, .empty, 0.5), 0.5)
    // Removing pane3 should collapse the bottom row entirely
    let pane3 = makePane()
    let root: PaneLayoutNode = .split(.vertical,
        .split(.horizontal, .leaf(pane1), .leaf(pane2), 0.5),
        .split(.horizontal, .leaf(pane3), .empty, 0.5),
        0.5)
    var layout = PaneLayout(root: root)
    layout.remove(pane: pane3)
    XCTAssertEqual(layout.leaves.count, 2)
    // Should have collapsed to just split(.h, pane1, pane2, 0.5)
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
    // Should be nil since the left side is empty
    XCTAssertNil(adjacent)
}

func test_swapPaneSkipsEmpty() {
    let pane1 = makePane()
    // pane1 is next to .empty — swap should be a no-op
    let root: PaneLayoutNode = .split(.horizontal, .leaf(pane1), .empty, 0.5)
    var layout = PaneLayout(root: root)
    let target = layout.swapPane(pane1, direction: .right)
    XCTAssertNil(target)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PaneLayoutTests 2>&1 | tail -20`
Expected: compilation errors (`.empty` does not exist, `PaneLayout(root:)` does not exist)

- [ ] **Step 3: Add `.empty` case and `init(root:)` to `PaneLayout.swift`**

In `Mistty/Models/PaneLayout.swift`:

1. Add `case empty` to `PaneLayoutNode` (after line 8):

```swift
indirect enum PaneLayoutNode {
    case leaf(MisttyPane)
    case empty
    case split(SplitDirection, PaneLayoutNode, PaneLayoutNode, CGFloat)
}
```

2. Add `init(root:)` to `PaneLayout` (after line 18):

```swift
init(root: PaneLayoutNode) {
    self.root = root
}
```

3. Update `collectLeaves` (line 25-31):

```swift
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
```

4. Update `removeNode` (line 50-65) — treat `.empty` as a non-matching leaf, and collapse if sibling becomes `.empty`:

```swift
private static func removeNode(_ node: PaneLayoutNode, target: Int) -> PaneLayoutNode? {
    switch node {
    case .leaf(let p) where p.id == target:
        return nil
    case .leaf:
        return node
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
```

5. Update `insertSplit` (line 72-90):

```swift
case .empty:
    return node
```

6. Update `rotate` (line 99-118):

```swift
case .empty:
    return node
```

7. Update `adjustRatio` (line 129-155):

```swift
case .empty:
    return node
```

8. Update `findPath` (line 167-179):

```swift
case .empty:
    return nil
```

9. Update `swapLeaves` (line 235-243):

```swift
case .empty:
    return node
```

10. Update `firstLeaf` (line 246-249) — skip `.empty`:

```swift
private static func firstLeaf(_ node: PaneLayoutNode) -> MisttyPane? {
    switch node {
    case .leaf(let p): return p
    case .empty: return nil
    case .split(_, let a, let b, _): return firstLeaf(a) ?? firstLeaf(b)
    }
}
```

11. Update `lastLeaf` (line 253-256) — skip `.empty`, try `b` first then fall back to `a`:

```swift
private static func lastLeaf(_ node: PaneLayoutNode) -> MisttyPane? {
    switch node {
    case .leaf(let p): return p
    case .empty: return nil
    case .split(_, let a, let b, _): return lastLeaf(b) ?? lastLeaf(a)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PaneLayoutTests 2>&1 | tail -20`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/PaneLayout.swift MisttyTests/Models/PaneLayoutTests.swift
git commit -m "feat: add .empty case to PaneLayoutNode for standard layouts"
```

---

## Task 2: Create `LayoutEngine` with tests

**Files:**
- Create: `Mistty/Models/LayoutEngine.swift`
- Create: `MisttyTests/Models/LayoutEngineTests.swift`

- [ ] **Step 1: Write failing tests for `LayoutEngine`**

Create `MisttyTests/Models/LayoutEngineTests.swift`:

```swift
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
        // split(.h, A, B, 0.5)
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
        // split(.h, A, split(.h, B, C, 0.5), 0.333)
        if case .split(.horizontal, .leaf(let a), .split(.horizontal, .leaf(let b), .leaf(let c), let innerRatio), let outerRatio) = node {
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
        // split(.h, main, other, 0.66)
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
        // split(.h, main, split(.v, B, C, 0.5), 0.66)
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
        // 2 panes: 2x1 grid = split(.h, A, B, 0.5)
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
        // 3 panes: 2x2 grid with one empty
        // split(.v, split(.h, A, B, 0.5), split(.h, C, .empty, 0.5), 0.5)
        let layout = PaneLayout(root: node)
        XCTAssertEqual(layout.leaves.count, 3)
        XCTAssertEqual(layout.leaves.map(\.id), panes.map(\.id))

        // Verify structure: top row has 2 panes, bottom row has 1 pane + 1 empty
        if case .split(.vertical,
            .split(.horizontal, .leaf(let a), .leaf(let b), _),
            .split(.horizontal, .leaf(let c), .empty, _),
            let ratio) = node {
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
        // 4 panes: 2x2 grid, no empties
        if case .split(.vertical,
            .split(.horizontal, .leaf(let a), .leaf(let b), _),
            .split(.horizontal, .leaf(let c), .leaf(let d), _),
            _) = node {
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
        // 5 panes: 3x2 grid with one empty
        // cols=ceil(sqrt(5))=3, rows=ceil(5/3)=2
        let layout = PaneLayout(root: node)
        XCTAssertEqual(layout.leaves.count, 5)
        XCTAssertEqual(layout.leaves.map(\.id), panes.map(\.id))
    }

    // MARK: - Single pane guard

    func test_singlePaneReturnsLeaf() {
        let panes = makePanes(1)
        let node = LayoutEngine.apply(.evenHorizontal, to: panes)
        if case .leaf(let p) = node {
            XCTAssertEqual(p.id, panes[0].id)
        } else {
            XCTFail("Single pane should return a leaf node")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LayoutEngineTests 2>&1 | tail -20`
Expected: compilation error (`LayoutEngine` does not exist)

- [ ] **Step 3: Create `LayoutEngine.swift`**

Create `Mistty/Models/LayoutEngine.swift`:

```swift
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
    private static func evenSplit(_ direction: SplitDirection, _ panes: [MisttyPane]) -> PaneLayoutNode {
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
    private static func mainSplit(_ direction: SplitDirection, _ panes: [MisttyPane]) -> PaneLayoutNode {
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

        // Combine rows with even vertical splits
        return evenSplitNodes(.vertical, rowNodes)
    }

    /// Build a single row: even horizontal split of panes, padded with .empty nodes.
    private static func buildRow(_ panes: [MisttyPane], emptyCount: Int) -> PaneLayoutNode {
        var nodes: [PaneLayoutNode] = panes.map { .leaf($0) }
        nodes.append(contentsOf: Array(repeating: PaneLayoutNode.empty, count: emptyCount))
        return evenSplitNodes(.horizontal, nodes)
    }

    /// Even split of arbitrary PaneLayoutNodes (not just panes).
    private static func evenSplitNodes(_ direction: SplitDirection, _ nodes: [PaneLayoutNode]) -> PaneLayoutNode {
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LayoutEngineTests 2>&1 | tail -20`
Expected: all tests PASS

- [ ] **Step 5: Run all tests to make sure nothing is broken**

Run: `swift test 2>&1 | tail -20`
Expected: all tests PASS

- [ ] **Step 6: Commit**

```bash
git add Mistty/Models/LayoutEngine.swift MisttyTests/Models/LayoutEngineTests.swift
git commit -m "feat: add LayoutEngine with 5 standard layout builders"
```

---

## Task 3: Add `applyStandardLayout` to `MisttyTab` and wire up UI

**Files:**
- Modify: `Mistty/Models/MisttyTab.swift`
- Modify: `Mistty/Views/Terminal/PaneLayoutView.swift`
- Modify: `Mistty/Views/Terminal/WindowModeHints.swift`
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Add `applyStandardLayout()` to `MisttyTab`**

In `Mistty/Models/MisttyTab.swift`, add after `closePane` (after line 74):

```swift
func applyStandardLayout(_ standardLayout: StandardLayout) {
    let currentPanes = layout.leaves
    guard currentPanes.count >= 2 else { return }
    zoomedPane = nil
    layout = PaneLayout(root: LayoutEngine.apply(standardLayout, to: currentPanes))
    panes = layout.leaves
}
```

- [ ] **Step 2: Handle `.empty` in `PaneLayoutView`**

In `Mistty/Views/Terminal/PaneLayoutView.swift`, add a case before `.leaf` (inside `switch node`, after line 15):

```swift
case .empty:
    Color(nsColor: .windowBackgroundColor)
```

- [ ] **Step 3: Add layout hint to `WindowModeHints`**

In `Mistty/Views/Terminal/WindowModeHints.swift`:

1. Add a `paneCount` property to the struct (after line 5):

```swift
var paneCount: Int = 1
```

2. Change `normalHints` to a computed property that conditionally includes layout hint. Insert before the `("esc", "exit")` entry (line 15), only when `paneCount >= 2`:

```swift
private var normalHints: [(key: String, label: String)] {
    var hints: [(key: String, label: String)] = [
        ("←↑↓→", "swap"),
        ("⌘+arrows", "resize"),
        ("z", "zoom"),
        ("b", "break to tab"),
        ("m", "join to tab"),
        ("r", "rotate"),
    ]
    if paneCount >= 2 {
        hints.append(("1-5", "layout"))
    }
    hints.append(("esc", "exit"))
    return hints
}
```

3. Pass `paneCount` from the call site. Find where `WindowModeHints` is instantiated in `PaneView` and add `paneCount: tab.panes.count`. The exact call site will need to be located — search for `WindowModeHints(` in the codebase.

- [ ] **Step 4: Add keyCode handling in `ContentView`**

In `Mistty/App/ContentView.swift`, in the `installWindowModeMonitor` function, add cases to the `switch event.keyCode` block (before the `default:` case at line 494). Only apply when 2+ panes:

```swift
case 18, 19, 20, 21, 23:  // 1-5: standard layouts
    if let tab = store.activeSession?.activeTab, tab.panes.count >= 2 {
        let layout: StandardLayout = switch event.keyCode {
            case 18: .evenHorizontal
            case 19: .evenVertical
            case 20: .mainHorizontal
            case 21: .mainVertical
            case 23: .tiled
            default: .evenHorizontal  // unreachable
        }
        tab.applyStandardLayout(layout)
        tab.windowModeState = .inactive
        removeWindowModeMonitor()
    }
    return nil
```

- [ ] **Step 5: Build and verify**

Run: `swift build 2>&1 | tail -20`
Expected: build succeeds

- [ ] **Step 6: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: all tests PASS

- [ ] **Step 7: Commit**

```bash
git add Mistty/Models/MisttyTab.swift Mistty/Views/Terminal/PaneLayoutView.swift Mistty/Views/Terminal/WindowModeHints.swift Mistty/App/ContentView.swift
git commit -m "feat: wire up standard layouts in window mode (1-5 keys)"
```
