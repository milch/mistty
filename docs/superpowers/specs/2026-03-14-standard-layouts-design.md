# Standard Layouts for Window Mode

## Summary

Add number key shortcuts (1-5) in window mode to apply standard pane layouts to the current tab. Only active when the tab has 2+ panes.

## Layouts

| Key | Name | Description |
|-----|------|-------------|
| 1 | even-horizontal | All panes side by side, equal widths |
| 2 | even-vertical | All panes stacked vertically, equal heights |
| 3 | main-horizontal | First pane on left (66%), rest stacked vertically on right |
| 4 | main-vertical | First pane on top (66%), rest arranged horizontally below |
| 5 | tiled | Grid layout, cols = ceil(sqrt(N)), rows = ceil(N/cols), last row padded with empty cells matching column width |

"First pane" = leftmost leaf of the current layout tree (i.e. pane ordering is preserved from the existing tree traversal).

## Design

### New: `StandardLayout` enum

```swift
enum StandardLayout {
    case evenHorizontal, evenVertical, mainHorizontal, mainVertical, tiled
}
```

### New: `LayoutEngine` struct

`@MainActor` struct with static methods. Each takes `[MisttyPane]` and returns `PaneLayoutNode`.

- `evenHorizontal(_:)` — left-leaning chain of horizontal splits. At each level, ratio = `1.0 / Double(panesInThisSubtree)`. For 3 panes: top ratio = 1/3 (33%), next level = 1/2 (50%).
- `evenVertical(_:)` — same, vertical splits
- `mainHorizontal(_:)` — `split(.horizontal, main, evenVertical(rest), 0.66)`
- `mainVertical(_:)` — `split(.vertical, main, evenHorizontal(rest), 0.66)`
- `tiled(_:)` — builds row splits, each row is an even horizontal split; rows combined with even vertical splits. Last row padded with `.empty` to match column count.

Public entry point: `static func apply(_ layout: StandardLayout, to panes: [MisttyPane]) -> PaneLayoutNode`

### Modified: `PaneLayoutNode`

Add `case empty` to the enum:

```swift
indirect enum PaneLayoutNode {
    case leaf(MisttyPane)
    case empty
    case split(SplitDirection, PaneLayoutNode, PaneLayoutNode, CGFloat)
}
```

**All** `switch` statements on `PaneLayoutNode` must be updated to handle `.empty`. This includes both public methods and private helpers in `PaneLayout`:

- `collectLeaves`: return `[]` for `.empty`
- `removeNode`: treat `.empty` like a non-matching leaf (return node as-is). After removing a pane, if the sibling is `.empty`, collapse the parent split (return `nil` so the empty node is also removed).
- `insertSplit`: return node as-is for `.empty`
- `rotate`: return node as-is for `.empty`
- `adjustRatio`: return node as-is for `.empty`
- `findPath`: return `nil` for `.empty`
- `swapLeaves`: return node as-is for `.empty`
- `firstLeaf` / `lastLeaf`: return `nil` for `.empty`, recurse into non-empty side if one child is empty
- `findAdjacent`: when finding the adjacent leaf, skip `.empty` nodes (if `firstLeaf`/`lastLeaf` returns nil due to empty, continue searching)

### Modified: `PaneLayout`

Add a new initializer to allow direct root assignment:

```swift
init(root: PaneLayoutNode) {
    self.root = root
}
```

### Modified: `PaneLayoutView`

Render `.empty` as a `Color(.windowBackgroundColor)` view (matches macOS window background).

### Modified: `MisttyTab`

Add method:

```swift
func applyStandardLayout(_ layout: StandardLayout) {
    let currentPanes = self.layout.leaves
    guard currentPanes.count >= 2 else { return }
    // Clear zoom before applying layout
    zoomedPane = nil
    layout = PaneLayout(root: LayoutEngine.apply(layout, to: currentPanes))
    panes = layout.leaves  // Sync panes array
    // activePane is unchanged (still references a pane in the new tree)
}
```

### Modified: `ContentView` (window mode key handler)

In the `.normal` window mode state, handle keyCodes 18-23 (digits 1-5) to match existing codebase conventions (which use `event.keyCode`). Only when `tab.panes.count >= 2`. Applying a layout exits window mode (matches existing pattern where structural changes like `breakPaneToTab` exit window mode).

```swift
case 18: tab.applyStandardLayout(.evenHorizontal)   // 1
case 19: tab.applyStandardLayout(.evenVertical)      // 2
case 20: tab.applyStandardLayout(.mainHorizontal)    // 3
case 21: tab.applyStandardLayout(.mainVertical)      // 4
case 23: tab.applyStandardLayout(.tiled)             // 5
```

Note: keyCodes 18-21 are digits 1-4, keyCode 23 is digit 5 (keyCode 22 is digit 6). These do not conflict with `.joinPick` mode which handles digits via `event.characters`.

### Modified: `WindowModeHints`

Add layout keys to hint text: `1-5: layouts`. Only show when `tab.panes.count >= 2`.

## Tree Shape Examples

### 2 panes (A, B)

**even-horizontal:** `split(.h, A, B, 0.5)`
**main-horizontal:** `split(.h, A, B, 0.66)`
**tiled:** `split(.h, A, B, 0.5)` (1x2 grid = same as even-horizontal)

### 3 panes (A, B, C)

**even-horizontal:**
```
split(.h, A, split(.h, B, C, 0.5), 0.333)
```

**main-horizontal:**
```
split(.h, A, split(.v, B, C, 0.5), 0.66)
```

**tiled (2x2 grid):**
```
split(.v,
  split(.h, A, B, 0.5),
  split(.h, C, .empty, 0.5),
0.5)
```

### 4 panes (A, B, C, D)

**tiled (2x2 grid):**
```
split(.v,
  split(.h, A, B, 0.5),
  split(.h, C, D, 0.5),
0.5)
```

### 5 panes (A, B, C, D, E)

**tiled (3x2 grid):**
```
split(.v,
  split(.h, A, split(.h, B, C, 0.5), 0.333),
  split(.h, D, split(.h, E, .empty, 0.5), 0.333),
0.5)
```

## Edge Cases

- **Single pane:** Guard prevents layout application. Hints hidden.
- **Zoomed pane:** Zoom is cleared before applying layout.
- **Closing a pane next to `.empty`:** `removeNode` collapses the `.empty` sibling along with the removed pane, preventing orphaned empty rows.

## Testing

`LayoutEngineTests`:
- Each layout with 2, 3, 4, 5 panes
- Verify tree structure, ratios, leaf order
- Verify `.empty` placement in tiled with odd pane counts
- Verify `PaneLayoutNode.leaves` skips `.empty`

`PaneLayoutTests` (additions):
- Verify `adjacentPane` skips `.empty` nodes
- Verify `swapPane` skips `.empty` targets
- Verify `remove` collapses `.empty` siblings
- Verify `firstLeaf`/`lastLeaf` skip `.empty`
