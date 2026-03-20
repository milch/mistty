# Copy Mode Phase 2: Scrollback & Search Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend copy mode to navigate scrollback and search the full terminal history with all-match highlighting.

**Architecture:** Scrolling uses `ghostty_surface_binding_action` with `scroll_page_lines`/`scroll_to_row` for exact row-level control. Scrollbar state is tracked via `GHOSTTY_ACTION_SCROLLBAR` callback for viewport-to-screen coordinate mapping. Search scans `GHOSTTY_POINT_SCREEN` coordinates with a `screenLineReader` closure. Motions that cross viewport edges return `.scroll` + `.needsContinuation` actions; ContentView scrolls, then calls `continuePendingMotion` with a fresh `lineReader`.

**Tech Stack:** Swift 6, SwiftUI, SPM, libghostty C API, XCTest

**Spec:** `docs/superpowers/specs/2026-03-19-copy-mode-phase2-design.md`

**Test runner:** `swift test --filter MisttyTests.CopyModeStateTests` or `swift test --filter MisttyTests.CopyModeIntegrationTests`

---

## Chunk 1: Foundation — Actions, Sub-Modes, and Scrollbar State

### Task 1: Add new CopyModeAction cases and update CopySubMode

**Files:**
- Modify: `Mistty/Models/CopyModeAction.swift`

- [ ] **Step 1: Update CopySubMode enum**

Replace `.search` with `.searchForward` and `.searchReverse` in `CopyModeAction.swift`:

```swift
enum CopySubMode: Equatable {
  case normal
  case visual
  case visualLine
  case visualBlock
  case searchForward
  case searchReverse
}
```

- [ ] **Step 2: Add PendingMotion, ContinuationState, SearchDirection enums**

Add after `FindCharKind` in the same file:

```swift
enum SearchDirection: Equatable {
  case forward
  case reverse
}

enum PendingMotion: Equatable {
  case wordForward(bigWord: Bool)
  case wordBackward(bigWord: Bool)
  case wordEndForward(bigWord: Bool)
  case wordEndBackward(bigWord: Bool)
  case lineDown
  case lineUp
}

struct ContinuationState: Equatable {
  let motion: PendingMotion
  let remaining: Int
}
```

- [ ] **Step 3: Add new CopyModeAction cases**

Add to the `CopyModeAction` enum:

```swift
case scroll(deltaRows: Int)
case needsContinuation
case searchNext
case searchPrev
```

- [ ] **Step 4: Do not commit yet** — this change breaks compilation until Tasks 2-5 update all references to `.search`. Continue to Task 2 immediately.

### Task 2: Update CopyModeState for new sub-modes and add new state fields

**Files:**
- Modify: `Mistty/Models/CopyModeState.swift`

- [ ] **Step 1: Write failing tests for new state fields**

Add to `MisttyTests/Models/CopyModeStateTests.swift`:

```swift
// MARK: - Phase 2: Search direction and continuation

func test_searchDirection_defaultsToForward() {
  let state = makeState()
  XCTAssertEqual(state.searchDirection, .forward)
}

func test_pendingContinuation_defaultsToNil() {
  let state = makeState()
  XCTAssertNil(state.pendingContinuation)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CopyModeStateTests/test_searchDirection 2>&1 | tail -5`
Expected: FAIL — `searchDirection` property doesn't exist yet

- [ ] **Step 3: Add new state fields to CopyModeState**

In `CopyModeState.swift`, add after the `desiredCol` property (line 25):

```swift
  // Phase 2: Scrollback & search
  var searchDirection: SearchDirection = .forward
  var searchMatchIndex: Int?
  var searchMatchTotal: Int?
  var pendingContinuation: ContinuationState?
```

- [ ] **Step 4: Update isSearching computed property**

Change line 37 from:
```swift
var isSearching: Bool { subMode == .search }
```
to:
```swift
var isSearching: Bool { subMode == .searchForward || subMode == .searchReverse }
```

- [ ] **Step 5: Update handleEscape for new sub-modes**

In `handleEscape()` (line 118), replace the `.search` case:

```swift
case .searchForward, .searchReverse:
  subMode = .normal
  searchQuery = ""
  pendingContinuation = nil
  return [.cancelSearch, .enterSubMode(.normal)]
case .normal:
  pendingContinuation = nil
  return [.exitCopyMode]
```

Also add `pendingContinuation = nil` to the visual modes case.

- [ ] **Step 6: Update handleKey search dispatch**

Change line 82 from:
```swift
if subMode == .search {
```
to:
```swift
if isSearching {
```

- [ ] **Step 7: Update handleNormalKey for / and ? and n/N**

In `handleNormalKey`, change the `/` case (line 206-209):
```swift
case "/":
  subMode = .searchForward
  searchDirection = .forward
  searchQuery = ""
  return [.startSearch]
```

Add `?` case after `/`:
```swift
case "?":
  subMode = .searchReverse
  searchDirection = .reverse
  searchQuery = ""
  return [.startSearch]
```

Change `n` case (line 210-212):
```swift
case "n":
  if !searchQuery.isEmpty { return [.searchNext] }
  return []
case "N":
  if !searchQuery.isEmpty { return [.searchPrev] }
  return []
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --filter CopyModeStateTests 2>&1 | tail -10`
Expected: All tests PASS (new tests + existing tests still pass)

- [ ] **Step 9: Do not commit yet** — continue to Task 3 to fix remaining compilation errors.

### Task 3: Update CopyModeOverlay for new sub-modes

**Files:**
- Modify: `Mistty/Views/Terminal/CopyModeOverlay.swift`

- [ ] **Step 1: Update mode indicator for search sub-modes**

In `CopyModeOverlay.swift`, replace the search check at line 39:

```swift
if state.subMode == .searchForward || state.subMode == .searchReverse {
  let prefix = state.subMode == .searchForward ? "/" : "?"
  let matchInfo: String
  if let idx = state.searchMatchIndex, let total = state.searchMatchTotal {
    matchInfo = "  [\(idx)/\(total)]"
  } else {
    matchInfo = ""
  }
  Text("\(prefix)\(state.searchQuery)\u{2588}\(matchInfo)")
    .font(.system(size: 11, weight: .bold, design: .monospaced))
    .foregroundStyle(.white)
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(Color.blue.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
```

- [ ] **Step 2: Update modeIndicatorText to remove .search case**

Replace the `modeIndicatorText` computed property:

```swift
private var modeIndicatorText: String {
  switch state.subMode {
  case .normal: return "-- COPY --"
  case .visual: return "-- VISUAL --"
  case .visualLine: return "-- VISUAL LINE --"
  case .visualBlock: return "-- VISUAL BLOCK --"
  case .searchForward, .searchReverse: return ""  // handled separately
  }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Do not commit yet** — continue to Task 4.

### Task 4: Update CopyModeHelpOverlay with phase 2 keybindings

**Files:**
- Modify: `Mistty/Views/Terminal/CopyModeHelpOverlay.swift`

- [ ] **Step 1: Update hint arrays**

Replace `actionHints` (line 28) with two separate arrays — split search and scrolling into their own columns:

```swift
private let searchHints: [(key: String, label: String)] = [
  ("/", "search forward"),
  ("?", "search backward"),
  ("n", "next match"),
  ("N", "prev match"),
]

private let scrollHints: [(key: String, label: String)] = [
  ("Ctrl-D", "half page down"),
  ("Ctrl-U", "half page up"),
  ("Ctrl-F", "full page down"),
  ("Ctrl-B", "full page up"),
]

private let actionHints: [(key: String, label: String)] = [
  ("y", "yank selection"),
  ("g?", "toggle this help"),
  ("Esc", "exit copy mode"),
]
```

- [ ] **Step 2: Update body to include new columns**

Update the `HStack` in `body` to include all columns:

```swift
HStack(alignment: .top, spacing: 20) {
  hintColumn(title: "Navigation", hints: navHints)
  hintColumn(title: "Selection", hints: selectionHints)
  hintColumn(title: "Find on Line", hints: findHints)
  hintColumn(title: "Search", hints: searchHints)
  hintColumn(title: "Scrolling", hints: scrollHints)
  hintColumn(title: "Actions", hints: actionHints)
}
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Do not commit yet** — continue to Task 5.

### Task 5: Update ContentView action handler for new sub-modes

**Files:**
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Update action switch for new cases**

In `installCopyModeMonitor()` (line 665), update the action switch. Change the `.confirmSearch` case and add new cases:

```swift
case .confirmSearch:
  performSearch(&state)
case .searchNext:
  performSearch(&state)
case .searchPrev:
  performSearch(&state)
case .scroll:
  break  // TODO: implement in Task 6
case .needsContinuation:
  break  // TODO: implement in Task 8
```

- [ ] **Step 2: Update search mode check**

In line 644, change:
```swift
if event.modifierFlags.contains(.command) && state.subMode != .search {
```
to:
```swift
if event.modifierFlags.contains(.command) && !state.isSearching {
```

- [ ] **Step 3: Build and run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests PASS, build succeeds

- [ ] **Step 4: Build and run all tests to verify everything compiles with the sub-mode rename**

Run: `swift test 2>&1 | tail -10`
Expected: All tests PASS

- [ ] **Step 5: Commit all foundation changes together (Tasks 1-5)**

```bash
git add Mistty/Models/CopyModeAction.swift Mistty/Models/CopyModeState.swift Mistty/Views/Terminal/CopyModeOverlay.swift Mistty/Views/Terminal/CopyModeHelpOverlay.swift Mistty/App/ContentView.swift MisttyTests/Models/CopyModeStateTests.swift
git commit -m "feat(copy-mode): phase 2 foundation — new sub-modes, actions, search direction, help overlay"
```

### Task 6: Add scrollbar state tracking via GHOSTTY_ACTION_SCROLLBAR

**Files:**
- Modify: `Mistty/App/GhosttyApp.swift`
- Modify: `Mistty/Views/Terminal/TerminalSurfaceView.swift` (or wherever pane state lives)

- [ ] **Step 1: Add ScrollbarState struct**

Add to `Mistty/Models/CopyModeAction.swift` (bottom of file, keeps terminal types together):

```swift
struct ScrollbarState: Equatable {
  var total: UInt64 = 0
  var offset: UInt64 = 0
  var len: UInt64 = 0
}
```

- [ ] **Step 2: Add scrollbarState property to TerminalSurfaceView**

In `TerminalSurfaceView.swift`, add a published/observable property:

```swift
var scrollbarState = ScrollbarState()
```

- [ ] **Step 3: Handle GHOSTTY_ACTION_SCROLLBAR in action callback**

In `GhosttyApp.swift`, add a case in `actionCallback` before the `default:` (line 65):

```swift
case GHOSTTY_ACTION_SCROLLBAR:
  if target.tag == GHOSTTY_TARGET_SURFACE {
    let surface = target.target.surface
    let sb = action.action.scrollbar
    DispatchQueue.main.async {
      guard let userdata = ghostty_surface_userdata(surface) else { return }
      let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
      view.scrollbarState = ScrollbarState(total: sb.total, offset: sb.offset, len: sb.len)
    }
  }
  return true
```

- [ ] **Step 4: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/CopyModeAction.swift Mistty/App/GhosttyApp.swift Mistty/Views/Terminal/TerminalSurfaceView.swift
git commit -m "feat(copy-mode): track scrollbar state via GHOSTTY_ACTION_SCROLLBAR"
```

---

## Chunk 2: Scrolling — Paging Commands and j/k Scroll

### Task 7: Implement paging commands (Ctrl-D/U/F/B)

**Files:**
- Modify: `Mistty/Models/CopyModeState.swift`
- Test: `MisttyTests/Models/CopyModeStateTests.swift`

- [ ] **Step 1: Write failing tests for paging**

Add to `CopyModeStateTests.swift`:

```swift
// MARK: - Phase 2: Paging

func test_ctrlD_returnsScrollDown() {
  var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
  let actions = state.handleKey(key: "d", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: 12)))  // rows/2 = 12
}

func test_ctrlU_returnsScrollUp() {
  var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
  let actions = state.handleKey(key: "u", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: -12)))
}

func test_ctrlF_returnsFullPageDown() {
  var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
  let actions = state.handleKey(key: "f", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: 24)))
}

func test_ctrlB_returnsFullPageUp() {
  var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
  let actions = state.handleKey(key: "b", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: -24)))
}

func test_5ctrlD_pagesDown5HalfScreens() {
  var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
  // Type "5" then Ctrl-D
  _ = state.handleKey(key: "5", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
  let actions = state.handleKey(key: "d", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: 60)))  // 5 * 12
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CopyModeStateTests/test_ctrlD 2>&1 | tail -5`
Expected: FAIL

- [ ] **Step 3: Implement paging in handleNormalKey**

In `CopyModeState.swift`, add Ctrl-key handling at the top of `handleNormalKey`, before the `switch key` statement (after `desiredCol = nil` on line 162). The key insight: `charactersIgnoringModifiers` gives us `"d"`, `"u"`, `"f"`, `"b"` even with Ctrl held, so these keys will arrive in the existing switch. But we need to check for `.control` modifier. Add before the switch:

```swift
// Ctrl-key paging commands
if modifiers.contains(.control) {
  switch key {
  case "d":
    let delta = count * (rows / 2)
    return [.scroll(deltaRows: delta), .cursorMoved]
  case "u":
    let delta = count * (rows / 2)
    return [.scroll(deltaRows: -delta), .cursorMoved]
  case "f":
    let delta = count * rows
    return [.scroll(deltaRows: delta), .cursorMoved]
  case "b":
    let delta = count * rows
    return [.scroll(deltaRows: -delta), .cursorMoved]
  default:
    break
  }
}
```

Note: Ctrl-v (visual block) is already handled earlier in the switch via the `"v"` case checking `.control`. That still works because the existing code checks `modifiers.contains(.control)` inside the `"v"` case. However, with this new block, we need to make sure `"v"` with Ctrl doesn't match here. Since there's no `"v"` case in the new switch, it falls through correctly.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CopyModeStateTests 2>&1 | tail -10`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/CopyModeState.swift MisttyTests/Models/CopyModeStateTests.swift
git commit -m "feat(copy-mode): implement Ctrl-D/U/F/B paging commands"
```

### Task 8: Implement scroll-on-boundary for j/k

**Files:**
- Modify: `Mistty/Models/CopyModeState.swift`
- Test: `MisttyTests/Models/CopyModeStateTests.swift`

- [ ] **Step 1: Write failing tests for j/k at viewport edges**

Add to `CopyModeStateTests.swift`:

```swift
// MARK: - Phase 2: j/k scrolling at viewport edges

func test_j_atBottomRow_returnsScroll() {
  var state = makeState(rows: 24, cursorRow: 23, cursorCol: 0)
  let actions = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: 1)))
  XCTAssertEqual(state.cursorRow, 23)  // cursor stays at bottom
}

func test_k_atTopRow_returnsScroll() {
  var state = makeState(rows: 24, cursorRow: 0, cursorCol: 0)
  let actions = state.handleKey(key: "k", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: -1)))
  XCTAssertEqual(state.cursorRow, 0)  // cursor stays at top
}

func test_3j_atRow22_scrollsBy2() {
  // rows=24, cursor at row 22. 3j would go to row 25, but max is 23.
  // Should scroll by 2 (the overflow) and cursor lands at row 23.
  var state = makeState(rows: 24, cursorRow: 22, cursorCol: 0)
  let actions = state.handleKey(key: "3", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
  let actions2 = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
  XCTAssertTrue(actions2.contains(.scroll(deltaRows: 2)))
  XCTAssertEqual(state.cursorRow, 23)
}

func test_j_inMiddle_noScroll() {
  var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
  let actions = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
  XCTAssertFalse(actions.contains(where: { if case .scroll = $0 { return true }; return false }))
  XCTAssertEqual(state.cursorRow, 11)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CopyModeStateTests/test_j_atBottom 2>&1 | tail -5`
Expected: FAIL — currently j at bottom row 23 stays at 23 with no scroll action

- [ ] **Step 3: Rewrite moveUp/moveDown to return scroll delta**

Replace the existing `moveUp()` and `moveDown()` methods:

```swift
/// Move up by count rows. Returns scroll delta if cursor hits top edge.
private mutating func moveVertical(delta: Int) -> Int {
  let targetRow = cursorRow + delta
  if targetRow < 0 {
    cursorRow = 0
    return targetRow  // negative = scroll up
  } else if targetRow >= rows {
    cursorRow = rows - 1
    return targetRow - (rows - 1)  // positive = scroll down
  } else {
    cursorRow = targetRow
    return 0
  }
}
```

- [ ] **Step 4: Update j/k in handleNormalKey to use moveVertical**

Replace the j and k cases:

```swift
case "j":
  cursorCol = savedDesiredCol ?? cursorCol
  desiredCol = savedDesiredCol ?? cursorCol
  let scrollDelta = moveVertical(delta: count)
  var result = motionActions()
  if scrollDelta != 0 {
    result.insert(.scroll(deltaRows: scrollDelta), at: 0)
  }
  return result
case "k":
  cursorCol = savedDesiredCol ?? cursorCol
  desiredCol = savedDesiredCol ?? cursorCol
  let scrollDelta = moveVertical(delta: -count)
  var result = motionActions()
  if scrollDelta != 0 {
    result.insert(.scroll(deltaRows: scrollDelta), at: 0)
  }
  return result
```

- [ ] **Step 5: Remove old moveUp/moveDown (now unused)**

Delete the `moveUp()` and `moveDown()` methods. Keep `moveLeft()` and `moveRight()` since they don't need scroll support (horizontal scroll is not in scope).

Also update the `repeatMotion` helper or remove it if no longer used by j/k. Check if any other code calls `moveUp()`/`moveDown()` — they shouldn't since j/k were the only callers.

- [ ] **Step 6: Run all tests**

Run: `swift test --filter CopyModeStateTests 2>&1 | tail -10`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add Mistty/Models/CopyModeState.swift MisttyTests/Models/CopyModeStateTests.swift
git commit -m "feat(copy-mode): j/k scroll viewport at edges instead of clamping"
```

### Task 9: Wire scroll actions in ContentView

**Files:**
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Implement scroll action handler**

In `installCopyModeMonitor()`, replace the `.scroll` case:

```swift
case .scroll(let deltaRows):
  if let pane = store.activeSession?.activeTab?.activePane,
     let surface = pane.surfaceView.surface {
    let offsetBefore = pane.surfaceView.scrollbarState.offset
    // Use binding action for exact row-level scrolling
    let actionStr = "scroll_page_lines:\(deltaRows)"
    _ = ghostty_surface_binding_action(surface, actionStr, UInt(actionStr.utf8.count))
    // Check actual scroll delta (may be less near scrollback boundaries)
    let offsetAfter = pane.surfaceView.scrollbarState.offset
    let actualDelta = Int(offsetAfter) - Int(offsetBefore)
    // Adjust anchor for visual selection stability
    if let anchor = state.anchor {
      state.anchor = (row: anchor.row - actualDelta, col: anchor.col)
    }
  }
```

- [ ] **Step 2: Build and test**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat(copy-mode): wire scroll actions to ghostty_surface_binding_action"
```

---

## Chunk 3: Cross-Line Motion Continuation

### Task 10: Implement continuePendingMotion and update word motions

**Files:**
- Modify: `Mistty/Models/CopyModeState.swift`
- Test: `MisttyTests/Models/CopyModeStateTests.swift`

- [ ] **Step 1: Write failing tests for word motion at viewport edge**

```swift
// MARK: - Phase 2: Word motion at viewport edge

func test_w_atLastRow_returnsScrollAndContinuation() {
  // Cursor on last row, at end of line content — w should scroll down
  let lines = Array(repeating: "hello world", count: 24)
  let lineReader: (Int) -> String? = { row in
    row >= 0 && row < lines.count ? lines[row] : nil
  }
  var state = makeState(rows: 24, cursorRow: 23, cursorCol: 6)
  // "world" ends at col 10, w from col 6 goes to end — should try next line
  // At row 23 (last row), this should produce scroll + continuation
  let actions = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: lineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: 1)))
  XCTAssertTrue(actions.contains(.needsContinuation))
  XCTAssertNotNil(state.pendingContinuation)
}

func test_b_atFirstRow_returnsScrollAndContinuation() {
  let lines = Array(repeating: "hello world", count: 24)
  let lineReader: (Int) -> String? = { row in
    row >= 0 && row < lines.count ? lines[row] : nil
  }
  var state = makeState(rows: 24, cursorRow: 0, cursorCol: 0)
  let actions = state.handleKey(key: "b", keyCode: 0, modifiers: [], lineReader: lineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: -1)))
  XCTAssertTrue(actions.contains(.needsContinuation))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CopyModeStateTests/test_w_atLastRow 2>&1 | tail -5`
Expected: FAIL

- [ ] **Step 3: Update wordMotion to detect viewport edge and return continuation**

Replace the `wordMotion` method with a version that accepts a `pendingMotionType` for continuation:

```swift
private mutating func wordMotion(
  count: Int,
  pendingMotionType: PendingMotion,
  lineReader: (Int) -> String?,
  motion: (String, Int) -> Int?
) -> [CopyModeAction] {
  for i in 0..<count {
    guard let line = lineReader(cursorRow) else { break }
    if let newCol = motion(line, cursorCol) {
      cursorCol = newCol
    } else {
      if cursorRow < rows - 1 {
        cursorRow += 1
        cursorCol = 0
        if let nextLine = lineReader(cursorRow) {
          let chars = Array(nextLine)
          var j = 0
          while j < chars.count && chars[j].isWhitespace { j += 1 }
          if j < chars.count { cursorCol = j }
        }
      } else {
        let remaining = count - i - 1
        pendingContinuation = ContinuationState(
          motion: pendingMotionType, remaining: remaining + 1)
        return [.scroll(deltaRows: 1), .needsContinuation]
      }
    }
  }
  return motionActions()
}
```

Update all call sites in `handleNormalKey` to pass the correct `pendingMotionType`:
- `"w"`: `.wordForward(bigWord: false)`
- `"W"`: `.wordForward(bigWord: true)`
- `"e"`: `.wordEndForward(bigWord: false)`
- `"E"`: `.wordEndForward(bigWord: true)`

- [ ] **Step 4: Similarly update wordMotionBackward**

Same pattern but scrolling up and using negative delta:

```swift
private mutating func wordMotionBackward(
  count: Int,
  pendingMotionType: PendingMotion,
  lineReader: (Int) -> String?,
  motion: (String, Int) -> Int?
) -> [CopyModeAction] {
  for i in 0..<count {
    guard let line = lineReader(cursorRow) else { break }
    if let newCol = motion(line, cursorCol) {
      cursorCol = newCol
    } else {
      if cursorRow > 0 {
        cursorRow -= 1
        if let prevLine = lineReader(cursorRow) {
          cursorCol = max(0, prevLine.count - 1)
        } else {
          cursorCol = 0
        }
      } else {
        let remaining = count - i - 1
        pendingContinuation = ContinuationState(
          motion: pendingMotionType, remaining: remaining + 1)
        return [.scroll(deltaRows: -1), .needsContinuation]
      }
    }
  }
  return motionActions()
}
```

Update call sites:
- `"b"`: `.wordBackward(bigWord: false)`
- `"B"`: `.wordBackward(bigWord: true)`
- `"ge"` (in handlePendingG): `.wordEndBackward(bigWord: false)`
- `"gE"` (in handlePendingG): `.wordEndBackward(bigWord: true)`

- [ ] **Step 5: Implement continuePendingMotion**

Add this public method to `CopyModeState`:

```swift
// MARK: - Continuation

mutating func continuePendingMotion(
  lineReader: (Int) -> String?
) -> [CopyModeAction] {
  guard let continuation = pendingContinuation else { return [] }
  pendingContinuation = nil

  switch continuation.motion {
  case .wordForward(let bigWord):
    let motionFn: (String, Int) -> Int? = { line, col in
      WordMotion.nextWordStart(in: line, from: col, bigWord: bigWord)
    }
    // Position cursor at start of line after scroll
    cursorCol = 0
    if let line = lineReader(cursorRow) {
      let chars = Array(line)
      var i = 0
      while i < chars.count && chars[i].isWhitespace { i += 1 }
      if i < chars.count { cursorCol = i }
    }
    if continuation.remaining > 1 {
      return wordMotion(
        count: continuation.remaining - 1,
        pendingMotionType: continuation.motion,
        lineReader: lineReader,
        motion: motionFn)
    }
    clampCursorToLineContent(lineReader: lineReader)
    return motionActions()

  case .wordBackward(let bigWord):
    let motionFn: (String, Int) -> Int? = { line, col in
      WordMotion.prevWordStart(in: line, from: col, bigWord: bigWord)
    }
    if let line = lineReader(cursorRow) {
      cursorCol = max(0, line.count - 1)
    }
    if continuation.remaining > 1 {
      return wordMotionBackward(
        count: continuation.remaining - 1,
        pendingMotionType: continuation.motion,
        lineReader: lineReader,
        motion: motionFn)
    }
    clampCursorToLineContent(lineReader: lineReader)
    return motionActions()

  case .wordEndForward(let bigWord):
    let motionFn: (String, Int) -> Int? = { line, col in
      WordMotion.nextWordEnd(in: line, from: col, bigWord: bigWord)
    }
    cursorCol = 0
    if continuation.remaining > 1 {
      return wordMotion(
        count: continuation.remaining - 1,
        pendingMotionType: continuation.motion,
        lineReader: lineReader,
        motion: motionFn)
    }
    clampCursorToLineContent(lineReader: lineReader)
    return motionActions()

  case .wordEndBackward(let bigWord):
    let motionFn: (String, Int) -> Int? = { line, col in
      WordMotion.prevWordEnd(in: line, from: col, bigWord: bigWord)
    }
    if let line = lineReader(cursorRow) {
      cursorCol = max(0, line.count - 1)
    }
    if continuation.remaining > 1 {
      return wordMotionBackward(
        count: continuation.remaining - 1,
        pendingMotionType: continuation.motion,
        lineReader: lineReader,
        motion: motionFn)
    }
    clampCursorToLineContent(lineReader: lineReader)
    return motionActions()

  case .lineDown:
    // j already scrolled, just clamp
    clampCursorToLineContent(lineReader: lineReader)
    return motionActions()

  case .lineUp:
    clampCursorToLineContent(lineReader: lineReader)
    return motionActions()
  }
}
```

- [ ] **Step 6: Write test for continuePendingMotion**

```swift
func test_continuePendingMotion_completesWordMotion() {
  var state = makeState(rows: 24, cursorRow: 23, cursorCol: 0)
  state.pendingContinuation = ContinuationState(
    motion: .wordForward(bigWord: false), remaining: 1)
  let newLines = Array(repeating: "foo bar baz", count: 24)
  let lineReader: (Int) -> String? = { row in
    row >= 0 && row < newLines.count ? newLines[row] : nil
  }
  let actions = state.continuePendingMotion(lineReader: lineReader)
  // Should have landed on first word of the new viewport content
  XCTAssertEqual(state.cursorCol, 0)  // "foo" starts at 0
  XCTAssertTrue(actions.contains(.cursorMoved))
  XCTAssertNil(state.pendingContinuation)
}
```

- [ ] **Step 7: Run all tests**

Run: `swift test --filter CopyModeStateTests 2>&1 | tail -10`
Expected: All tests PASS

- [ ] **Step 8: Commit**

```bash
git add Mistty/Models/CopyModeState.swift MisttyTests/Models/CopyModeStateTests.swift
git commit -m "feat(copy-mode): word motions scroll at viewport edge with continuation"
```

### Task 11: Wire continuation in ContentView

**Files:**
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Handle .needsContinuation in action loop**

Update the `.needsContinuation` case in the action switch:

```swift
case .needsContinuation:
  // After scroll is processed, call continuePendingMotion with fresh lineReader.
  // Check scrollbar state before and after to detect if scroll actually moved.
  if let pane = store.activeSession?.activeTab?.activePane {
    let offsetBefore = pane.surfaceView.scrollbarState.offset
    // The scroll action was already applied above — check if viewport moved
    let offsetAfter = pane.surfaceView.scrollbarState.offset
    if offsetBefore == offsetAfter && state.pendingContinuation != nil {
      // Viewport didn't move (at scrollback boundary) — cancel continuation
      state.pendingContinuation = nil
      break
    }
  }
  let continuationActions = state.continuePendingMotion(lineReader: lineReader)
  for contAction in continuationActions {
    switch contAction {
    case .scroll(let delta):
      if let pane = store.activeSession?.activeTab?.activePane,
         let surface = pane.surfaceView.surface {
        if let anchor = state.anchor {
          state.anchor = (row: anchor.row - delta, col: anchor.col)
        }
        let actionStr = "scroll_page_lines:\(delta)"
        _ = ghostty_surface_binding_action(surface, actionStr, UInt(actionStr.utf8.count))
      }
    case .needsContinuation:
      // Recursive continuation — re-invoke with boundary check
      if let pane = store.activeSession?.activeTab?.activePane {
        let ob = pane.surfaceView.scrollbarState.offset
        // scroll was just applied above
        let oa = pane.surfaceView.scrollbarState.offset
        if ob == oa {
          state.pendingContinuation = nil
          break
        }
      }
      let moreActions = state.continuePendingMotion(lineReader: lineReader)
      for a in moreActions {
        if case .scroll(let d) = a,
           let pane = store.activeSession?.activeTab?.activePane,
           let surface = pane.surfaceView.surface {
          if let anchor = state.anchor {
            state.anchor = (row: anchor.row - d, col: anchor.col)
          }
          let actionStr = "scroll_page_lines:\(d)"
          _ = ghostty_surface_binding_action(surface, actionStr, UInt(actionStr.utf8.count))
        }
      }
    default:
      break
    }
  }
```

- [ ] **Step 2: Build and test**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat(copy-mode): wire continuation handler in ContentView"
```

---

## Chunk 4: Full-Scrollback Search

### Task 12: Add screenLineReader and upgrade performSearch

**Files:**
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Add readScreenLine helper**

Add a new method next to `readTerminalLine`:

```swift
private func readScreenLine(row: Int) -> String? {
  guard let pane = store.activeSession?.activeTab?.activePane,
        let surface = pane.surfaceView.surface
  else { return nil }

  let size = ghostty_surface_size(surface)

  var sel = ghostty_selection_s()
  sel.top_left.tag = GHOSTTY_POINT_SCREEN
  sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
  sel.top_left.x = 0
  sel.top_left.y = UInt32(row)
  sel.bottom_right.tag = GHOSTTY_POINT_SCREEN
  sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
  sel.bottom_right.x = UInt32(size.columns - 1)
  sel.bottom_right.y = UInt32(row)
  sel.rectangle = false

  var text = ghostty_text_s()
  guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
  defer { ghostty_surface_free_text(surface, &text) }
  guard let ptr = text.text else { return nil }
  return String(cString: ptr)
}
```

- [ ] **Step 2: Rewrite performSearch for full scrollback**

Replace the existing `performSearch` method:

```swift
private func performSearch(_ state: inout CopyModeState) {
  guard !state.searchQuery.isEmpty,
        let pane = store.activeSession?.activeTab?.activePane,
        let surface = pane.surfaceView.surface
  else { return }

  let scrollbar = pane.surfaceView.scrollbarState
  let totalRows = Int(scrollbar.total)
  let viewportOffset = Int(scrollbar.offset)
  guard totalRows > 0 else { return }

  // Convert cursor to screen coordinates
  let cursorScreenRow = state.cursorRow + viewportOffset

  let isForward = state.searchDirection == .forward

  // Scan from cursor position in the search direction, wrapping around
  for i in 1...totalRows {
    let screenRow: Int
    if isForward {
      screenRow = (cursorScreenRow + i) % totalRows
    } else {
      screenRow = (cursorScreenRow - i + totalRows) % totalRows
    }

    guard let line = readScreenLine(row: screenRow) else { continue }

    // Search within the line — for reverse search, find last match on line
    let options: String.CompareOptions = isForward
      ? .caseInsensitive
      : [.caseInsensitive, .backwards]

    if let range = line.range(of: state.searchQuery, options: options) {
      let col = line.distance(from: line.startIndex, to: range.lowerBound)
      let cols = Int(ghostty_surface_size(surface).columns)

      // Scroll to make the match visible
      let viewportRows = Int(scrollbar.len)
      let targetOffset = max(0, screenRow - viewportRows / 2)
      let actionStr = "scroll_to_row:\(targetOffset)"
      _ = ghostty_surface_binding_action(surface, actionStr, UInt(actionStr.utf8.count))

      // Update cursor to viewport-relative position
      // After scrolling, the new viewport offset is targetOffset
      state.cursorRow = screenRow - targetOffset
      state.cursorCol = min(col, cols - 1)
      state.desiredCol = nil
      break
    }
  }
}
```

- [ ] **Step 3: Update .searchNext and .searchPrev action handlers**

In the action switch, update these cases:

```swift
case .confirmSearch:
  performSearch(&state)
  countSearchMatches(&state)
case .searchNext:
  // searchDirection already set from initial search
  performSearch(&state)
case .searchPrev:
  // Temporarily flip direction for this search
  let original = state.searchDirection
  state.searchDirection = original == .forward ? .reverse : .forward
  performSearch(&state)
  state.searchDirection = original
```

- [ ] **Step 4: Add match counting**

Add a new method. Note: this runs synchronously for now. For large scrollback (10k+ lines), consider moving to an async background queue in a future pass.

```swift
private func countSearchMatches(_ state: inout CopyModeState) {
  guard !state.searchQuery.isEmpty,
        let pane = store.activeSession?.activeTab?.activePane
  else { return }

  let scrollbar = pane.surfaceView.scrollbarState
  let totalRows = Int(scrollbar.total)
  let viewportOffset = Int(scrollbar.offset)
  let cursorScreenRow = state.cursorRow + viewportOffset

  var total = 0
  var currentIndex = 0

  for row in 0..<totalRows {
    guard let line = readScreenLine(row: row) else { continue }
    var searchStart = line.startIndex
    while let range = line.range(of: state.searchQuery, options: .caseInsensitive, range: searchStart..<line.endIndex) {
      total += 1
      let matchCol = line.distance(from: line.startIndex, to: range.lowerBound)
      if row < cursorScreenRow || (row == cursorScreenRow && matchCol <= state.cursorCol) {
        currentIndex = total
      }
      searchStart = range.upperBound
    }
  }

  state.searchMatchTotal = total > 0 ? total : nil
  state.searchMatchIndex = total > 0 ? currentIndex : nil
}
```

- [ ] **Step 5: Build and test**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat(copy-mode): full-scrollback search with forward/reverse and match count"
```

---

## Chunk 5: Search Highlighting and Yank with Screen Coordinates

### Task 13: Add SearchHighlightView

**Files:**
- Create: `Mistty/Views/Terminal/SearchHighlightView.swift`

- [ ] **Step 1: Create SearchHighlightView**

```swift
import SwiftUI

struct SearchHighlightView: View {
  let query: String
  let currentMatchRow: Int?
  let currentMatchCol: Int?
  let lineReader: (Int) -> String?
  let cellWidth: CGFloat
  let cellHeight: CGFloat
  let rows: Int

  var body: some View {
    Canvas { context, size in
      guard !query.isEmpty else { return }

      for row in 0..<rows {
        guard let line = lineReader(row) else { continue }

        var searchStart = line.startIndex
        while let range = line.range(of: query, options: .caseInsensitive, range: searchStart..<line.endIndex) {
          let col = line.distance(from: line.startIndex, to: range.lowerBound)
          let matchLen = line.distance(from: range.lowerBound, to: range.upperBound)

          let isCurrent = row == currentMatchRow && col == currentMatchCol
          let color: Color = isCurrent
            ? .orange.opacity(0.6)
            : .yellow.opacity(0.3)

          let rect = CGRect(
            x: CGFloat(col) * cellWidth,
            y: CGFloat(row) * cellHeight,
            width: CGFloat(matchLen) * cellWidth,
            height: cellHeight
          )
          context.fill(Path(rect), with: .color(color))

          searchStart = range.upperBound
        }
      }
    }
  }
}
```

- [ ] **Step 2: Integrate into CopyModeOverlay**

In `CopyModeOverlay.swift`, add a `searchQuery` property (or derive from `state`). Add `SearchHighlightView` to the ZStack, before the cursor:

```swift
// Search highlights
if !state.searchQuery.isEmpty, let reader = lineReader {
  SearchHighlightView(
    query: state.searchQuery,
    currentMatchRow: state.cursorRow,
    currentMatchCol: state.cursorCol,
    lineReader: reader,
    cellWidth: cellWidth,
    cellHeight: cellHeight,
    rows: state.rows
  )
  .offset(x: gridOffsetX, y: gridOffsetY)
}
```

- [ ] **Step 3: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Mistty/Views/Terminal/SearchHighlightView.swift Mistty/Views/Terminal/CopyModeOverlay.swift
git commit -m "feat(copy-mode): add search highlight overlay for all visible matches"
```

### Task 14: Update yankSelection for off-screen anchors

**Files:**
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Update readGhosttyText to support screen coordinates**

Add a `pointTag` parameter:

```swift
private func readGhosttyText(
  surface: ghostty_surface_t,
  startRow: Int, startCol: Int,
  endRow: Int, endCol: Int,
  rectangle: Bool,
  pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT
) -> String? {
  var sel = ghostty_selection_s()
  sel.top_left.tag = pointTag
  sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
  sel.top_left.x = UInt32(startCol)
  sel.top_left.y = UInt32(startRow)
  sel.bottom_right.tag = pointTag
  sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
  sel.bottom_right.x = UInt32(endCol)
  sel.bottom_right.y = UInt32(endRow)
  sel.rectangle = rectangle

  var text = ghostty_text_s()
  guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
  defer { ghostty_surface_free_text(surface, &text) }
  guard let ptr = text.text else { return nil }
  return String(cString: ptr)
}
```

- [ ] **Step 2: Update yankSelection to use screen coordinates when anchor is off-screen**

In `yankSelection()`, after getting `anchor` and `state`, check if anchor is out of viewport:

```swift
let anchorOutOfViewport = anchor.row < 0 || anchor.row >= state.rows
let useScreenCoords = anchorOutOfViewport

if useScreenCoords {
  let scrollbar = pane.surfaceView.scrollbarState
  let offset = Int(scrollbar.offset)
  let screenAnchorRow = anchor.row + offset
  let screenCursorRow = state.cursorRow + offset
  // Use screen coordinates for all reads in this yank
  // Update the switch cases to pass GHOSTTY_POINT_SCREEN and screen-relative rows
}
```

Update each case in the switch to conditionally use screen coordinates:

```swift
case .visual:
  let aRow = useScreenCoords ? anchor.row + Int(pane.surfaceView.scrollbarState.offset) : anchor.row
  let cRow = useScreenCoords ? state.cursorRow + Int(pane.surfaceView.scrollbarState.offset) : state.cursorRow
  let tag: ghostty_point_tag_e = useScreenCoords ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
  textToCopy = readGhosttyText(
    surface: surface,
    startRow: aRow, startCol: anchor.col,
    endRow: cRow, endCol: state.cursorCol,
    rectangle: false,
    pointTag: tag
  )
```

Apply the same pattern for `.visualLine` and `.visualBlock`.

- [ ] **Step 3: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat(copy-mode): yank selections that span beyond viewport using screen coords"
```

### Task 15: Final integration test and cleanup

**Files:**
- Modify: `MisttyTests/Models/CopyModeIntegrationTests.swift`

- [ ] **Step 1: Add integration tests for phase 2 features**

```swift
// MARK: - Phase 2: Search direction

func test_questionMark_entersReverseSearch() {
  var state = makeState(cursorRow: 10, cursorCol: 5)
  let actions = state.handleKey(key: "?", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.startSearch))
  XCTAssertEqual(state.subMode, .searchReverse)
  XCTAssertEqual(state.searchDirection, .reverse)
}

func test_N_returnsSearchPrev() {
  var state = makeState(cursorRow: 10, cursorCol: 5)
  state.searchQuery = "test"
  let actions = state.handleKey(key: "N", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.searchPrev))
}

func test_ctrlD_returnsHalfPageScroll() {
  var state = makeState(cursorRow: 10, cursorCol: 0)
  let actions = state.handleKey(key: "d", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
  XCTAssertTrue(actions.contains(.scroll(deltaRows: 12)))
}

func test_escape_clearsContinuation() {
  var state = makeState(cursorRow: 10, cursorCol: 0)
  state.pendingContinuation = ContinuationState(motion: .lineDown, remaining: 1)
  let actions = state.handleKey(key: "\u{1B}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
  XCTAssertNil(state.pendingContinuation)
  XCTAssertTrue(actions.contains(.exitCopyMode))
}
```

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1 | tail -15`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add MisttyTests/Models/CopyModeIntegrationTests.swift
git commit -m "test(copy-mode): add phase 2 integration tests"
```

- [ ] **Step 4: Update the ghostty submodule reference**

```bash
git add vendor/ghostty
git commit -m "chore: update ghostty submodule to v1.3.1"
```
