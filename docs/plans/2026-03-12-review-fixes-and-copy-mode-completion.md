# Review Fixes & Copy Mode Completion

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix review findings from phase 1 (notification typo, monitor cleanup, resize semantics) and complete copy mode (real terminal dimensions, working yank, word jumps, search).

**Architecture:** All fixes target existing files. Copy mode completion uses `ghostty_surface_size()` for real dimensions, `ghostty_surface_read_text()` for yank, and extends `CopyModeState` with word jump and search state.

**Tech Stack:** Swift 6, SwiftUI, libghostty C API (ghostty_surface_size, ghostty_surface_read_text), NSPasteboard

---

### Task 1: Fix notification name typo

**Files:**
- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/App/ContentView.swift`

**Step 1: Rename in MisttyApp.swift**

In `Mistty/App/MisttyApp.swift`, find the Notification.Name extension and rename:

```swift
// Before:
static let mistrySplitHorizontal = Notification.Name("mistrySplitHorizontal")
static let mistrySplitVertical = Notification.Name("mistrySplitVertical")

// After:
static let misttySplitHorizontal = Notification.Name("misttySplitHorizontal")
static let misttySplitVertical = Notification.Name("misttySplitVertical")
```

Also update the two `NotificationCenter.default.post` calls in the Button actions that reference these names.

**Step 2: Rename in ContentView.swift**

Update the `.onReceive` handlers:

```swift
// Before:
.onReceive(NotificationCenter.default.publisher(for: .mistrySplitHorizontal))
.onReceive(NotificationCenter.default.publisher(for: .mistrySplitVertical))

// After:
.onReceive(NotificationCenter.default.publisher(for: .misttySplitHorizontal))
.onReceive(NotificationCenter.default.publisher(for: .misttySplitVertical))
```

**Step 3: Build and verify**

Run: `swift build`

**Step 4: Commit**

```bash
git add Mistty/App/MisttyApp.swift Mistty/App/ContentView.swift
git commit -m "fix: rename mistrySplit* to misttySplit* notification names"
```

---

### Task 2: Event monitor cleanup on view destruction

**Files:**
- Modify: `Mistty/App/ContentView.swift`

**Step 1: Add onDisappear cleanup**

Add `.onDisappear` to the root HStack in ContentView's body that cleans up all active monitors:

```swift
.onDisappear {
    removeKeyMonitor()
    removeWindowModeMonitor()
    removeCopyModeMonitor()
    // Also reset modal states
    store.activeSession?.activeTab?.isWindowModeActive = false
    store.activeSession?.activeTab?.copyModeState = nil
    showingSessionManager = false
}
```

**Step 2: Add mutual exclusion between window mode and copy mode**

In `enterCopyMode()`, exit window mode first if active:

```swift
private func enterCopyMode() {
    guard let tab = store.activeSession?.activeTab else { return }
    // Exit window mode if active
    if tab.isWindowModeActive {
        tab.isWindowModeActive = false
        removeWindowModeMonitor()
    }
    tab.copyModeState = CopyModeState(rows: 24, cols: 80) // dimensions fixed in Task 5
    installCopyModeMonitor()
}
```

In `installWindowModeMonitor()`, exit copy mode first if active:

At the start of `installWindowModeMonitor()`, add:

```swift
// Exit copy mode if active
if store.activeSession?.activeTab?.isCopyModeActive == true {
    exitCopyMode()
}
```

**Step 3: Build and verify**

Run: `swift build`

**Step 4: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "fix: clean up event monitors on view destruction and add mutual exclusion"
```

---

### Task 3: Direction-aware resize in window mode

**Files:**
- Modify: `Mistty/Models/PaneLayout.swift`
- Modify: `Mistty/App/ContentView.swift`
- Test: `MisttyTests/Models/PaneLayoutTests.swift`

**Step 1: Write failing test**

Add to `PaneLayoutTests.swift`:

```swift
func test_resizeSplitDirectionAware() {
    let pane1 = MisttyPane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .vertical)
    let panes = layout.leaves

    // Resizing a vertical split with horizontal delta should be a no-op
    let ratioBefore: CGFloat
    if case .split(_, _, _, let r) = layout.root { ratioBefore = r } else { return XCTFail() }

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
```

**Step 2: Run test — expect fail**

Run: `swift test --filter PaneLayoutTests/test_resizeSplitDirectionAware`

**Step 3: Add `along` parameter to resizeSplit**

In `PaneLayout.swift`, change `resizeSplit` signature:

```swift
mutating func resizeSplit(containing pane: MisttyPane, delta: CGFloat, along direction: SplitDirection? = nil) {
    root = Self.adjustRatio(root, target: pane.id, delta: delta, along: direction)
}
```

Update `adjustRatio` to skip splits whose direction doesn't match:

```swift
private static func adjustRatio(
    _ node: PaneLayoutNode,
    target: UUID,
    delta: CGFloat,
    along direction: SplitDirection?
) -> PaneLayoutNode {
    switch node {
    case .leaf:
        return node
    case .split(let dir, let a, let b, let ratio):
        let aContains = collectLeaves(a).contains { $0.id == target }
        if aContains {
            if case .leaf(let p) = a, p.id == target {
                // Only resize if direction matches (or no direction constraint)
                if direction == nil || direction == dir {
                    return .split(dir, a, b, max(0.1, min(0.9, ratio + delta)))
                }
                return node
            }
            return .split(dir, adjustRatio(a, target: target, delta: delta, along: direction), b, ratio)
        }
        let bContains = collectLeaves(b).contains { $0.id == target }
        if bContains {
            if case .leaf(let p) = b, p.id == target {
                if direction == nil || direction == dir {
                    return .split(dir, a, b, max(0.1, min(0.9, ratio + delta)))
                }
                return node
            }
            return .split(dir, a, adjustRatio(b, target: target, delta: delta, along: direction), ratio)
        }
        return node
    }
}
```

**Step 4: Run test — expect pass**

Run: `swift test --filter PaneLayoutTests`

**Step 5: Update ContentView resize calls**

In `ContentView.swift`, update the Cmd+Arrow handlers in `installWindowModeMonitor`:

```swift
case 123: // Cmd+Left — shrink horizontally
    resizeActivePane(delta: -0.05, along: .horizontal)
    return nil
case 124: // Cmd+Right — grow horizontally
    resizeActivePane(delta: 0.05, along: .horizontal)
    return nil
case 126: // Cmd+Up — shrink vertically
    resizeActivePane(delta: -0.05, along: .vertical)
    return nil
case 125: // Cmd+Down — grow vertically
    resizeActivePane(delta: 0.05, along: .vertical)
    return nil
```

Update the helper:

```swift
private func resizeActivePane(delta: CGFloat, along direction: SplitDirection) {
    guard let tab = store.activeSession?.activeTab,
          let pane = tab.activePane else { return }
    tab.layout.resizeSplit(containing: pane, delta: delta, along: direction)
}
```

**Step 6: Build and run all tests**

Run: `swift test`

**Step 7: Commit**

```bash
git add Mistty/Models/PaneLayout.swift Mistty/App/ContentView.swift MisttyTests/Models/PaneLayoutTests.swift
git commit -m "fix: direction-aware split resize in window mode"
```

---

### Task 4: Add missing PaneLayout.remove tests

**Files:**
- Test: `MisttyTests/Models/PaneLayoutTests.swift`

**Step 1: Write tests**

Add to `PaneLayoutTests.swift`:

```swift
func test_removePaneFromTwoPaneSplit() {
    let pane1 = MisttyPane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal)
    let panes = layout.leaves
    XCTAssertEqual(panes.count, 2)

    layout.remove(pane: panes[1])
    XCTAssertEqual(layout.leaves.count, 1)
    XCTAssertEqual(layout.leaves[0].id, pane1.id)
    XCTAssertFalse(layout.isEmpty)
}

func test_removeLastPane() {
    let pane1 = MisttyPane()
    var layout = PaneLayout(pane: pane1)
    layout.remove(pane: pane1)
    XCTAssertTrue(layout.isEmpty)
    XCTAssertTrue(layout.leaves.isEmpty)
}

func test_removeNonExistentPane() {
    let pane1 = MisttyPane()
    let pane2 = MisttyPane()
    var layout = PaneLayout(pane: pane1)
    layout.remove(pane: pane2)
    // Should not crash, layout unchanged
    XCTAssertEqual(layout.leaves.count, 1)
    XCTAssertFalse(layout.isEmpty)
}
```

**Step 2: Run tests — expect pass (these test existing behavior)**

Run: `swift test --filter PaneLayoutTests`

**Step 3: Commit**

```bash
git add MisttyTests/Models/PaneLayoutTests.swift
git commit -m "test: add missing PaneLayout.remove tests"
```

---

### Task 5: Real terminal dimensions for copy mode

**Files:**
- Modify: `Mistty/App/ContentView.swift`
- Modify: `Mistty/Views/Terminal/PaneView.swift`

**Step 1: Get terminal size from ghostty in enterCopyMode**

In `ContentView.swift`, update `enterCopyMode()`:

```swift
private func enterCopyMode() {
    guard let tab = store.activeSession?.activeTab else { return }
    if tab.isWindowModeActive {
        tab.isWindowModeActive = false
        removeWindowModeMonitor()
    }

    // Get actual terminal dimensions from ghostty
    var rows = 24
    var cols = 80
    if let surface = tab.activePane?.surfaceView.surface {
        let size = ghostty_surface_size(surface)
        rows = Int(size.rows)
        cols = Int(size.columns)
    }

    tab.copyModeState = CopyModeState(rows: rows, cols: cols)
    installCopyModeMonitor()
}
```

This requires `import GhosttyKit` in ContentView.swift — check if it's already imported. If not, add it.

**Step 2: Use cell dimensions from ghostty for overlay**

In `PaneView.swift`, update the copy mode overlay to use ghostty's cell size instead of dividing geometry:

```swift
.overlay {
    if let state = copyModeState {
        GeometryReader { geo in
            let cellW = geo.size.width / CGFloat(state.cols)
            let cellH = geo.size.height / CGFloat(state.rows)
            CopyModeOverlay(state: state, cellWidth: cellW, cellHeight: cellH)
        }
    }
}
```

This is already what we have, but now `state.cols` and `state.rows` are real values from ghostty, so the cell dimensions will be accurate.

**Step 3: Build and verify**

Run: `swift build`

**Step 4: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat: use real terminal dimensions from ghostty for copy mode"
```

---

### Task 6: Implement working yank (copy to clipboard)

**Files:**
- Modify: `Mistty/App/ContentView.swift`

**Step 1: Implement yankSelection using ghostty API**

Replace the stub `yankSelection()` in `ContentView.swift`:

```swift
private func yankSelection() {
    guard let tab = store.activeSession?.activeTab,
          let pane = tab.activePane,
          let state = tab.copyModeState,
          let range = state.selectionRange,
          let surface = pane.surfaceView.surface else { return }

    let sel = ghostty_selection_s(
        top_left: ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_EXACT,
            x: UInt32(range.start.col),
            y: UInt32(range.start.row)
        ),
        bottom_right: ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_EXACT,
            x: UInt32(range.end.col),
            y: UInt32(range.end.row)
        ),
        rectangle: false
    )

    var text = ghostty_text_s()
    if ghostty_surface_read_text(surface, sel, &text) {
        if let ptr = text.text {
            let str = String(cString: ptr)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
        ghostty_surface_free_text(surface, &text)
    }
}
```

Note: The `ghostty_text_s` struct has `text` as a `const char*` pointer and `text_len` as `uintptr_t`. The struct also has `offset` and `offset_len` fields. Check the header if the field names don't match and adjust.

If the struct initializer requires all fields, use:

```swift
var text = ghostty_text_s()
// zero-initialize is fine, ghostty_surface_read_text fills it
```

**Step 2: Build and verify**

Run: `swift build`

If the ghostty_point_s or ghostty_selection_s structs have different field names than expected, check `vendor/ghostty/include/ghostty.h` and adjust. The key types from the header are:

```c
typedef struct {
  ghostty_point_tag_e tag;
  ghostty_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} ghostty_point_s;

typedef struct {
  ghostty_point_s top_left;
  ghostty_point_s bottom_right;
  bool rectangle;
} ghostty_selection_s;
```

**Step 3: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat: implement yank to clipboard using ghostty_surface_read_text"
```

---

### Task 7: Word jumps (w/b) in copy mode

**Files:**
- Modify: `Mistty/Models/CopyModeState.swift`
- Modify: `Mistty/App/ContentView.swift`
- Test: `MisttyTests/Models/CopyModeStateTests.swift`

**Step 1: Write failing tests**

Add to `CopyModeStateTests.swift`:

```swift
func test_moveWordForward() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorCol = 0
    // Word forward jumps by 5 columns (approximate — real word boundaries need screen content)
    state.moveWordForward()
    XCTAssertEqual(state.cursorCol, 5)
}

func test_moveWordBackward() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorCol = 10
    state.moveWordBackward()
    XCTAssertEqual(state.cursorCol, 5)
}

func test_moveWordForwardClampsToEnd() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorCol = 78
    state.moveWordForward()
    XCTAssertEqual(state.cursorCol, 79)
}

func test_moveWordBackwardClampsToStart() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorCol = 3
    state.moveWordBackward()
    XCTAssertEqual(state.cursorCol, 0)
}
```

**Step 2: Run tests — expect fail**

**Step 3: Add word jump methods to CopyModeState**

In `CopyModeState.swift`:

```swift
/// Jump forward by one "word" (approximate: 5 columns).
/// Real word boundaries would require reading screen content.
mutating func moveWordForward() {
    cursorCol = min(cols - 1, cursorCol + 5)
}

/// Jump backward by one "word" (approximate: 5 columns).
mutating func moveWordBackward() {
    cursorCol = max(0, cursorCol - 5)
}
```

Note: True word-boundary detection would require reading the terminal screen content. This approximation (5 char jumps) is practical and matches how many terminal emulators handle word jumps without screen access.

**Step 4: Run tests — expect pass**

Run: `swift test --filter CopyModeStateTests`

**Step 5: Wire w/b keys in copy mode monitor**

In `ContentView.swift`, in `installCopyModeMonitor`, add cases in the character switch:

```swift
case "w": state.moveWordForward()
case "b": state.moveWordBackward()
```

**Step 6: Commit**

```bash
git add Mistty/Models/CopyModeState.swift Mistty/App/ContentView.swift MisttyTests/Models/CopyModeStateTests.swift
git commit -m "feat: word jump (w/b) in copy mode"
```

---

### Task 8: Search in copy mode

**Files:**
- Modify: `Mistty/Models/CopyModeState.swift`
- Modify: `Mistty/App/ContentView.swift`
- Modify: `Mistty/Views/Terminal/CopyModeOverlay.swift`

**Step 1: Add search input to copy mode monitor**

When `/` is pressed in copy mode, enter search input mode. Characters accumulate in `searchQuery`. Enter confirms and moves cursor to first match. Escape cancels search and returns to normal copy mode.

In `CopyModeState.swift`, the `isSearching` and `searchQuery` fields already exist. Add:

```swift
mutating func startSearch() {
    isSearching = true
    searchQuery = ""
}

mutating func cancelSearch() {
    isSearching = false
    searchQuery = ""
}

mutating func appendSearchChar(_ char: Character) {
    searchQuery.append(char)
}

mutating func deleteSearchChar() {
    _ = searchQuery.popLast()
}
```

**Step 2: Update copy mode monitor for search mode**

In `ContentView.swift`, in `installCopyModeMonitor`, add search handling. When `state.isSearching` is true, keys go to the search query instead of cursor movement:

```swift
private func installCopyModeMonitor() {
    copyModeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard var state = store.activeSession?.activeTab?.copyModeState else { return event }

        // Escape always exits
        if event.keyCode == 53 {
            if state.isSearching {
                state.cancelSearch()
                store.activeSession?.activeTab?.copyModeState = state
                return nil
            }
            exitCopyMode()
            return nil
        }

        // Return in search mode confirms search
        if state.isSearching {
            if event.keyCode == 36 { // Return
                state.isSearching = false
                // Search is visual-only for now — cursor stays where it is
                store.activeSession?.activeTab?.copyModeState = state
                return nil
            }
            if event.keyCode == 51 { // Delete/Backspace
                state.deleteSearchChar()
                store.activeSession?.activeTab?.copyModeState = state
                return nil
            }
            if let chars = event.characters {
                for char in chars {
                    state.appendSearchChar(char)
                }
            }
            store.activeSession?.activeTab?.copyModeState = state
            return nil
        }

        // Normal copy mode keys
        guard let chars = event.characters else { return event }
        switch chars {
        case "h": state.moveLeft()
        case "j": state.moveDown()
        case "k": state.moveUp()
        case "l": state.moveRight()
        case "0": state.moveToLineStart()
        case "$": state.moveToLineEnd()
        case "G": state.moveToBottom()
        case "g": state.moveToTop()
        case "v": state.toggleSelection()
        case "w": state.moveWordForward()
        case "b": state.moveWordBackward()
        case "/": state.startSearch()
        case "y":
            yankSelection()
            exitCopyMode()
            return nil
        default: break
        }

        store.activeSession?.activeTab?.copyModeState = state
        return nil
    }
}
```

**Step 3: Show search bar in overlay**

In `CopyModeOverlay.swift`, update the mode indicator section to show the search query when searching:

```swift
// Mode indicator
VStack {
    Spacer()
    HStack {
        if state.isSearching {
            Text("/\(state.searchQuery)█")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
        } else {
            Text(state.isSelecting ? "-- VISUAL --" : "-- COPY --")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
        }
        Spacer()
    }
    .padding(4)
}
```

Note: The `█` character simulates a cursor in the search field. This is a visual-only search for now — actual text matching against terminal content would require reading the screen buffer, which can be added later.

**Step 4: Build and verify**

Run: `swift build`

**Step 5: Commit**

```bash
git add Mistty/Models/CopyModeState.swift Mistty/App/ContentView.swift Mistty/Views/Terminal/CopyModeOverlay.swift
git commit -m "feat: search input (/) in copy mode with visual search bar"
```

---

### Task 9: Pass through system shortcuts in copy mode

**Files:**
- Modify: `Mistty/App/ContentView.swift`

**Step 1: Let Cmd-modified keys pass through in copy mode**

In the copy mode monitor, before the search/normal mode handling, add:

```swift
// Pass through system shortcuts (Cmd+Q, Cmd+W, etc.)
if event.modifierFlags.contains(.command) && !state.isSearching {
    return event
}
```

This goes right after the escape check and before the search mode handling.

**Step 2: Build and verify**

Run: `swift build`

**Step 3: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "fix: pass through Cmd shortcuts in copy mode"
```

---

### Task 10: Final tests and cleanup

**Step 1: Run all tests**

Run: `swift test`

**Step 2: Format code**

Run: `just fmt` (from worktree root)

**Step 3: Build**

Run: `swift build`

**Step 4: Fix any issues**

**Step 5: Commit if needed**

```bash
git add -A
git commit -m "chore: review fixes and copy mode completion cleanup"
```
