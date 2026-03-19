# Copy Mode Phase 1: Motion & Selection Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor copy mode into an action-based state machine with proper vim word motions, f/F/t/T, number prefixes, visual line/block modes, and a help overlay.

**Architecture:** `CopyModeState` becomes a self-contained state machine with `handleKey()` returning `[CopyModeAction]`. ContentView's monitor becomes a thin dispatcher that forwards events and applies returned actions. A `lineReader` closure abstracts terminal content access for testability.

**Tech Stack:** Swift, SwiftUI (overlay rendering), AppKit (NSEvent monitoring), libghostty (terminal content reading)

**Spec:** `docs/superpowers/specs/2026-03-18-copy-mode-phase1-design.md`

**Build:** `swift build` / **Test:** `swift test` / **Format:** `just fmt`

---

## File Structure

| File | Responsibility | Action |
|------|---------------|--------|
| `Mistty/Models/CopyModeState.swift` | State machine: sub-modes, pending input, `handleKey()` returning actions | Major rewrite |
| `Mistty/Models/CopyModeAction.swift` | Action enum and supporting types (CopySubMode, FindCharKind) | Create |
| `Mistty/Models/WordMotion.swift` | Word/WORD boundary detection and motion logic | Create |
| `Mistty/Views/Terminal/CopyModeOverlay.swift` | Overlay rendering: character/line/block selection, help overlay | Modify |
| `Mistty/Views/Terminal/CopyModeHelpOverlay.swift` | Help overlay view (g?) | Create |
| `Mistty/App/ContentView.swift` | Thin key dispatcher, lineReader closure, action application | Modify (`installCopyModeMonitor`, `yankSelection`, `performSearch`) |
| `MisttyTests/Models/CopyModeStateTests.swift` | Tests for state machine, sub-modes, escape behavior | Major rewrite |
| `MisttyTests/Models/WordMotionTests.swift` | Tests for word/WORD boundary detection | Create |
| `MisttyTests/Models/CopyModeIntegrationTests.swift` | Tests for compound inputs (counts + motions, g-prefixed, f/t + repeat) | Create |

---

## Chunk 1: Foundation — Types, State Machine Skeleton, Basic Key Dispatch

### Task 1: Create CopyModeAction types

**Files:**
- Create: `Mistty/Models/CopyModeAction.swift`

- [ ] **Step 1: Create the action enum and supporting types**

```swift
// Mistty/Models/CopyModeAction.swift
import Foundation

enum CopySubMode: Equatable {
    case normal
    case visual
    case visualLine
    case visualBlock
    case search
}

enum FindCharKind: Equatable {
    case f, F, t, T

    var reversed: FindCharKind {
        switch self {
        case .f: return .F
        case .F: return .f
        case .t: return .T
        case .T: return .t
        }
    }

    var isForward: Bool {
        switch self {
        case .f, .t: return true
        case .F, .T: return false
        }
    }
}

enum CopyModeAction: Equatable {
    case cursorMoved
    case updateSelection
    case yank(text: String)
    case exitCopyMode
    case enterSubMode(CopySubMode)
    case showHelp
    case hideHelp
    case startSearch
    case updateSearch(query: String)
    case confirmSearch
    case cancelSearch
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Mistty/Models/CopyModeAction.swift
git commit -m "feat(copy-mode): add CopyModeAction enum and supporting types"
```

### Task 2: Refactor CopyModeState to action-based state machine skeleton

**Files:**
- Modify: `Mistty/Models/CopyModeState.swift`
- Modify: `MisttyTests/Models/CopyModeStateTests.swift`

This task replaces the existing mutating methods with a `handleKey()` method that returns actions. We start with the existing key bindings (h/j/k/l, 0/$, g/G, v, /, n, y) and the new escape behavior, without yet adding new features.

- [ ] **Step 1: Write failing tests for the new handleKey API**

Replace the test file with tests that exercise handleKey instead of calling individual mutating methods:

```swift
// MisttyTests/Models/CopyModeStateTests.swift
import XCTest
@testable import Mistty

final class CopyModeStateTests: XCTestCase {

    // Helper: create a state with a mock lineReader that returns nil
    private func makeState(rows: Int = 24, cols: Int = 80, cursorRow: Int? = nil, cursorCol: Int? = nil) -> CopyModeState {
        CopyModeState(rows: rows, cols: cols, cursorRow: cursorRow, cursorCol: cursorCol)
    }

    private let emptyLineReader: (Int) -> String? = { _ in nil }

    // MARK: - Initial state

    func test_initialState_cursorAtBottom() {
        let state = makeState()
        XCTAssertEqual(state.cursorRow, 23)
        XCTAssertEqual(state.cursorCol, 0)
        XCTAssertEqual(state.subMode, .normal)
    }

    // MARK: - Basic navigation

    func test_hjkl_movement() {
        var state = makeState(cursorRow: 10, cursorCol: 10)
        _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorRow, 11)

        _ = state.handleKey(key: "k", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorRow, 10)

        _ = state.handleKey(key: "l", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorCol, 11)

        _ = state.handleKey(key: "h", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorCol, 10)
    }

    func test_movement_clampsToEdges() {
        var state = makeState(cursorRow: 0, cursorCol: 0)
        _ = state.handleKey(key: "k", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorRow, 0)

        _ = state.handleKey(key: "h", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorCol, 0)
    }

    func test_lineStartEnd() {
        var state = makeState(cursorCol: 40)
        _ = state.handleKey(key: "0", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorCol, 0)

        _ = state.handleKey(key: "$", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorCol, 79)
    }

    func test_gGoesToTop_GGoesToBottom() {
        var state = makeState(cursorRow: 10)
        // g is pending, then g again -> go to top
        _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorRow, 0)
        XCTAssertEqual(state.cursorCol, 0)

        _ = state.handleKey(key: "G", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorRow, 23)
        XCTAssertEqual(state.cursorCol, 0)
    }

    // MARK: - Escape behavior (tmux-style)

    func test_escape_inNormal_exitsCopyMode() {
        var state = makeState()
        let actions = state.handleKey(key: "\u{1b}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
        XCTAssertTrue(actions.contains(.exitCopyMode))
    }

    func test_escape_inVisual_returnsToNormal() {
        var state = makeState()
        _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.subMode, .visual)

        let actions = state.handleKey(key: "\u{1b}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
        XCTAssertTrue(actions.contains(.enterSubMode(.normal)))
        XCTAssertEqual(state.subMode, .normal)
        XCTAssertNil(state.anchor)
    }

    func test_escape_inSearch_returnsToNormal() {
        var state = makeState()
        _ = state.handleKey(key: "/", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.subMode, .search)

        let actions = state.handleKey(key: "\u{1b}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
        XCTAssertTrue(actions.contains(.cancelSearch))
        XCTAssertTrue(actions.contains(.enterSubMode(.normal)))
    }

    // MARK: - Visual mode

    func test_v_entersVisual_setsAnchor() {
        var state = makeState(cursorRow: 5, cursorCol: 10)
        _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.subMode, .visual)
        XCTAssertEqual(state.anchor?.row, 5)
        XCTAssertEqual(state.anchor?.col, 10)
    }

    func test_v_inVisual_returnsToNormal() {
        var state = makeState()
        _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.subMode, .normal)
        XCTAssertNil(state.anchor)
    }

    // MARK: - Search

    func test_search_startAndCancel() {
        var state = makeState()
        let actions = state.handleKey(key: "/", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertTrue(actions.contains(.startSearch))
        XCTAssertEqual(state.subMode, .search)
        XCTAssertEqual(state.searchQuery, "")
    }

    // MARK: - y without selection is no-op

    func test_y_withoutSelection_isNoOp() {
        var state = makeState()
        let actions = state.handleKey(key: "y", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertTrue(actions.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CopyModeStateTests 2>&1 | tail -10`
Expected: Compilation errors (handleKey, subMode, anchor don't exist yet)

- [ ] **Step 3: Rewrite CopyModeState with handleKey skeleton**

```swift
// Mistty/Models/CopyModeState.swift
import AppKit

struct CopyModeState {
    let rows: Int
    let cols: Int
    var cursorRow: Int
    var cursorCol: Int = 0

    // Sub-mode
    var subMode: CopySubMode = .normal
    var anchor: (row: Int, col: Int)?

    // Search
    var searchQuery: String = ""

    // Pending input
    var pendingCount: Int?
    var pendingFindChar: FindCharKind?
    var lastFind: (kind: FindCharKind, char: Character)?
    var pendingG: Bool = false
    var showingHelp: Bool = false

    init(rows: Int, cols: Int, cursorRow: Int? = nil, cursorCol: Int? = nil) {
        self.rows = rows
        self.cols = cols
        self.cursorRow = min(max(cursorRow ?? (rows - 1), 0), rows - 1)
        self.cursorCol = min(max(cursorCol ?? 0, 0), cols - 1)
    }

    // MARK: - Backward compatibility (used by overlay, will be removed in later tasks)

    var isSelecting: Bool { subMode == .visual || subMode == .visualLine || subMode == .visualBlock }
    var isSearching: Bool { subMode == .search }

    var selectionRange: (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
        guard isSelecting, let anchor = anchor else { return nil }
        return (anchor, (cursorRow, cursorCol))
    }

    // MARK: - Key handling

    mutating func handleKey(
        key: Character,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        lineReader: (Int) -> String?
    ) -> [CopyModeAction] {

        // Help overlay: any key dismisses it (consumed)
        if showingHelp {
            showingHelp = false
            return [.hideHelp]
        }

        // Escape
        if keyCode == 53 {
            return handleEscape()
        }

        // Search mode
        if subMode == .search {
            return handleSearchKey(key: key, keyCode: keyCode)
        }

        // Pending find char: next key is the target character
        if pendingFindChar != nil {
            return handleFindCharTarget(key, lineReader: lineReader)
        }

        // Pending g: resolve two-key sequence
        if pendingG {
            return handlePendingG(key: key, keyCode: keyCode, modifiers: modifiers, lineReader: lineReader)
        }

        // Digit accumulation
        if let digit = key.wholeNumberValue {
            if digit != 0 || pendingCount != nil {
                pendingCount = (pendingCount ?? 0) * 10 + digit
                return []
            }
            // digit == 0 with no pending count -> line start (fall through)
        }

        return handleNormalKey(key: key, keyCode: keyCode, modifiers: modifiers, lineReader: lineReader)
    }

    // MARK: - Escape

    private mutating func handleEscape() -> [CopyModeAction] {
        switch subMode {
        case .visual, .visualLine, .visualBlock:
            subMode = .normal
            anchor = nil
            return [.enterSubMode(.normal)]
        case .search:
            subMode = .normal
            searchQuery = ""
            return [.cancelSearch, .enterSubMode(.normal)]
        case .normal:
            return [.exitCopyMode]
        }
    }

    // MARK: - Search keys

    private mutating func handleSearchKey(key: Character, keyCode: UInt16) -> [CopyModeAction] {
        if keyCode == 36 { // Return
            subMode = .normal
            return [.confirmSearch]
        }
        if keyCode == 51 { // Backspace
            _ = searchQuery.popLast()
            return [.updateSearch(query: searchQuery)]
        }
        searchQuery.append(key)
        return [.updateSearch(query: searchQuery)]
    }

    // MARK: - Normal key dispatch

    private mutating func handleNormalKey(
        key: Character,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        lineReader: (Int) -> String?
    ) -> [CopyModeAction] {
        let hadExplicitCount = pendingCount != nil
        let count = pendingCount ?? 1
        pendingCount = nil

        switch key {
        // Navigation
        case "h": return repeatMotion(count) { $0.moveLeft() }
        case "j": return repeatMotion(count) { $0.moveDown() }
        case "k": return repeatMotion(count) { $0.moveUp() }
        case "l": return repeatMotion(count) { $0.moveRight() }
        case "0": moveToLineStart(); return [.cursorMoved]
        case "$": moveToLineEnd(); return [.cursorMoved]
        case "G":
            if hadExplicitCount {
                // Explicit count: go to line N (1-indexed)
                cursorRow = min(max(count - 1, 0), rows - 1)
                cursorCol = 0
            } else {
                moveToBottom()
            }
            return [.cursorMoved]
        case "g":
            pendingG = true
            return []

        // Visual modes
        case "v":
            if modifiers.contains(.control) {
                return toggleVisualMode(.visualBlock)
            }
            return toggleVisualMode(.visual)
        case "V":
            return toggleVisualMode(.visualLine)

        // Search
        case "/":
            subMode = .search
            searchQuery = ""
            return [.startSearch]
        case "n":
            if !searchQuery.isEmpty { return [.confirmSearch] }
            return []

        // Find char
        case "f": pendingFindChar = .f; return []
        case "F": pendingFindChar = .F; return []
        case "t": pendingFindChar = .t; return []
        case "T": pendingFindChar = .T; return []
        case ";": return repeatFindChar(count: count, reverse: false, lineReader: lineReader)
        case ",": return repeatFindChar(count: count, reverse: true, lineReader: lineReader)

        // Word motions (placeholder — Task 4 replaces these)
        case "w": return repeatMotion(count) { $0.cursorCol = min($0.cols - 1, $0.cursorCol + 5) }
        case "b": return repeatMotion(count) { $0.cursorCol = max(0, $0.cursorCol - 5) }

        // Yank
        case "y":
            guard isSelecting else { return [] }
            // Yank is handled by ContentView reading the selection — signal it
            return [.exitCopyMode]

        default:
            return []
        }
    }

    // MARK: - Pending g resolution

    private mutating func handlePendingG(
        key: Character,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        lineReader: (Int) -> String?
    ) -> [CopyModeAction] {
        pendingG = false
        switch key {
        case "g":
            moveToTop()
            return [.cursorMoved]
        case "e":
            let count = pendingCount ?? 1
            pendingCount = nil
            return repeatMotion(count) { state in
                // ge: end of previous word (placeholder — Task 4 replaces)
                state.cursorCol = max(0, state.cursorCol - 5)
            }
        case "E":
            let count = pendingCount ?? 1
            pendingCount = nil
            return repeatMotion(count) { state in
                // gE: end of previous WORD (placeholder — Task 4 replaces)
                state.cursorCol = max(0, state.cursorCol - 5)
            }
        case "?":
            showingHelp.toggle()
            return showingHelp ? [.showHelp] : [.hideHelp]
        default:
            // Cancel g, process key normally
            return handleNormalKey(key: key, keyCode: keyCode, modifiers: modifiers, lineReader: lineReader)
        }
    }

    // MARK: - Visual mode toggling

    private mutating func toggleVisualMode(_ target: CopySubMode) -> [CopyModeAction] {
        if subMode == target {
            // Same key as current mode -> back to normal
            subMode = .normal
            anchor = nil
            return [.enterSubMode(.normal)]
        } else {
            // Enter visual or switch between visual modes
            if anchor == nil {
                anchor = (cursorRow, cursorCol)
            }
            subMode = target
            return [.enterSubMode(target), .updateSelection]
        }
    }

    // MARK: - Find char

    private mutating func handleFindCharTarget(_ char: Character, lineReader: (Int) -> String?) -> [CopyModeAction] {
        guard let kind = pendingFindChar else { return [] }
        pendingFindChar = nil
        lastFind = (kind: kind, char: char)

        let count = pendingCount ?? 1
        pendingCount = nil
        return executeFindChar(kind: kind, char: char, count: count, lineReader: lineReader)
    }

    private mutating func repeatFindChar(count: Int, reverse: Bool, lineReader: (Int) -> String?) -> [CopyModeAction] {
        guard let last = lastFind else { return [] }
        let kind = reverse ? last.kind.reversed : last.kind
        return executeFindChar(kind: kind, char: last.char, count: count, lineReader: lineReader)
    }

    private mutating func executeFindChar(kind: FindCharKind, char: Character, count: Int, lineReader: (Int) -> String?) -> [CopyModeAction] {
        guard let line = lineReader(cursorRow) else { return [] }
        let chars = Array(line)

        var found = 0
        var targetCol: Int?

        if kind.isForward {
            for i in (cursorCol + 1)..<chars.count {
                if chars[i] == char {
                    found += 1
                    if found == count {
                        targetCol = (kind == .t) ? i - 1 : i
                        break
                    }
                }
            }
        } else {
            for i in stride(from: cursorCol - 1, through: 0, by: -1) {
                if chars[i] == char {
                    found += 1
                    if found == count {
                        targetCol = (kind == .T) ? i + 1 : i
                        break
                    }
                }
            }
        }

        if let col = targetCol {
            cursorCol = col
            return motionActions()
        }
        return []
    }

    // MARK: - Movement helpers

    private mutating func moveUp() { cursorRow = max(0, cursorRow - 1) }
    private mutating func moveDown() { cursorRow = min(rows - 1, cursorRow + 1) }
    private mutating func moveLeft() { cursorCol = max(0, cursorCol - 1) }
    private mutating func moveRight() { cursorCol = min(cols - 1, cursorCol + 1) }
    private mutating func moveToLineStart() { cursorCol = 0 }
    private mutating func moveToLineEnd() { cursorCol = cols - 1 }
    private mutating func moveToTop() { cursorRow = 0; cursorCol = 0 }
    private mutating func moveToBottom() { cursorRow = rows - 1; cursorCol = 0 }

    private mutating func repeatMotion(_ count: Int, _ motion: (inout CopyModeState) -> Void) -> [CopyModeAction] {
        for _ in 0..<count { motion(&self) }
        return motionActions()
    }

    private func motionActions() -> [CopyModeAction] {
        if isSelecting {
            return [.cursorMoved, .updateSelection]
        }
        return [.cursorMoved]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CopyModeStateTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/CopyModeState.swift MisttyTests/Models/CopyModeStateTests.swift
git commit -m "feat(copy-mode): refactor CopyModeState to action-based state machine"
```

### Task 3: Update ContentView to use handleKey dispatcher

**Files:**
- Modify: `Mistty/App/ContentView.swift` (lines 634-700, 761-800, 802-830)

The ContentView monitor becomes a thin dispatcher. `performSearch` and `yankSelection` stay in ContentView since they need ghostty access. Note: yank deviates from the spec's `.yank(text:)` action because yank text extraction requires ghostty selection APIs that are only available in ContentView — so yank is signaled by `.exitCopyMode` and ContentView checks `isSelecting` before exiting.

- [ ] **Step 1: Rewrite installCopyModeMonitor to use handleKey**

Replace the body of the `installCopyModeMonitor()` method in ContentView.swift with:

```swift
private func installCopyModeMonitor() {
    copyModeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard var state = store.activeSession?.activeTab?.copyModeState else { return event }

        // Pass through system shortcuts (Cmd+*) when not searching
        if event.modifierFlags.contains(.command) && state.subMode != .search {
            return event
        }

        // Extract key from charactersIgnoringModifiers for correct Ctrl-v handling
        guard let keyStr = event.charactersIgnoringModifiers, let key = keyStr.first else { return event }

        let lineReader: (Int) -> String? = { row in
            self.readTerminalLine(row: row)
        }

        let actions = state.handleKey(
            key: key,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            lineReader: lineReader
        )

        // Apply actions
        for action in actions {
            switch action {
            case .cursorMoved:
                break // Position already in state
            case .updateSelection:
                break // Selection derived from state
            case .yank:
                break // Not used — yank is signaled by exitCopyMode
            case .exitCopyMode:
                // Yank if there's a selection before exiting
                if state.isSelecting {
                    store.activeSession?.activeTab?.copyModeState = state
                    yankSelection()
                }
                exitCopyMode()
                return nil
            case .enterSubMode:
                break // Sub-mode already in state
            case .showHelp, .hideHelp:
                break // showingHelp already in state
            case .startSearch:
                break // subMode already set to .search
            case .updateSearch:
                break // searchQuery already updated
            case .confirmSearch:
                performSearch(&state)
            case .cancelSearch:
                break // Already handled in state
            }
        }

        store.activeSession?.activeTab?.copyModeState = state
        return nil
    }
}
```

- [ ] **Step 2: Add readTerminalLine helper**

Add this method to ContentView (after the existing `performSearch` method):

```swift
private func readTerminalLine(row: Int) -> String? {
    guard let pane = store.activeSession?.activeTab?.activePane,
          let surface = pane.surfaceView.surface
    else { return nil }

    let size = ghostty_surface_size(surface)

    var sel = ghostty_selection_s()
    sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
    sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
    sel.top_left.x = 0
    sel.top_left.y = UInt32(row)
    sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
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

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "refactor(copy-mode): replace key dispatch in ContentView with handleKey"
```

### Task 4: Update CopyModeOverlay for sub-modes

**Files:**
- Modify: `Mistty/Views/Terminal/CopyModeOverlay.swift`

Update the mode indicator text to show the correct sub-mode.

- [ ] **Step 1: Update mode indicator**

Replace the mode indicator section (the `VStack` at the bottom) in CopyModeOverlay:

```swift
// Mode indicator
VStack {
    Spacer()
    HStack {
        if state.subMode == .search {
            Text("/\(state.searchQuery)█")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
        } else {
            Text(modeIndicatorText)
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

Add a computed property:

```swift
private var modeIndicatorText: String {
    switch state.subMode {
    case .normal: return "-- COPY --"
    case .visual: return "-- VISUAL --"
    case .visualLine: return "-- VISUAL LINE --"
    case .visualBlock: return "-- VISUAL BLOCK --"
    case .search: return "" // handled separately
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Mistty/Views/Terminal/CopyModeOverlay.swift
git commit -m "feat(copy-mode): update mode indicator for visual line/block sub-modes"
```

---

## Chunk 2: Word Motions

### Task 5: Create WordMotion module with boundary detection

**Files:**
- Create: `Mistty/Models/WordMotion.swift`
- Create: `MisttyTests/Models/WordMotionTests.swift`

- [ ] **Step 1: Write failing tests for word boundary detection**

```swift
// MisttyTests/Models/WordMotionTests.swift
import XCTest
@testable import Mistty

final class WordMotionTests: XCTestCase {

    // MARK: - Character classification

    func test_charClass_keyword() {
        XCTAssertEqual(WordMotion.charClass("a"), .keyword)
        XCTAssertEqual(WordMotion.charClass("Z"), .keyword)
        XCTAssertEqual(WordMotion.charClass("0"), .keyword)
        XCTAssertEqual(WordMotion.charClass("_"), .keyword)
    }

    func test_charClass_punctuation() {
        XCTAssertEqual(WordMotion.charClass("."), .punctuation)
        XCTAssertEqual(WordMotion.charClass("-"), .punctuation)
        XCTAssertEqual(WordMotion.charClass("/"), .punctuation)
        XCTAssertEqual(WordMotion.charClass("("), .punctuation)
    }

    func test_charClass_whitespace() {
        XCTAssertEqual(WordMotion.charClass(" "), .whitespace)
        XCTAssertEqual(WordMotion.charClass("\t"), .whitespace)
    }

    // MARK: - w motion (next word start)

    func test_w_simpleWords() {
        // "hello world" cursor at 0 -> should go to 6
        let result = WordMotion.nextWordStart(in: "hello world", from: 0, bigWord: false)
        XCTAssertEqual(result, 6)
    }

    func test_w_punctuationBoundary() {
        // "foo.bar" cursor at 0 -> should go to 3 (the dot is a different class)
        let result = WordMotion.nextWordStart(in: "foo.bar", from: 0, bigWord: false)
        XCTAssertEqual(result, 3)
    }

    func test_w_punctuationToWord() {
        // "foo.bar" cursor at 3 -> should go to 4
        let result = WordMotion.nextWordStart(in: "foo.bar", from: 3, bigWord: false)
        XCTAssertEqual(result, 4)
    }

    func test_W_skipsPunctuation() {
        // "foo.bar baz" cursor at 0 -> should go to 8 (WORD skips punct)
        let result = WordMotion.nextWordStart(in: "foo.bar baz", from: 0, bigWord: true)
        XCTAssertEqual(result, 8)
    }

    func test_w_atEndOfLine_returnsNil() {
        let result = WordMotion.nextWordStart(in: "hello", from: 4, bigWord: false)
        XCTAssertNil(result)
    }

    // MARK: - b motion (previous word start)

    func test_b_simpleWords() {
        // "hello world" cursor at 6 -> should go to 0
        let result = WordMotion.prevWordStart(in: "hello world", from: 6, bigWord: false)
        XCTAssertEqual(result, 0)
    }

    func test_b_punctuationBoundary() {
        // "foo.bar" cursor at 4 -> should go to 3
        let result = WordMotion.prevWordStart(in: "foo.bar", from: 4, bigWord: false)
        XCTAssertEqual(result, 3)
    }

    func test_B_skipsPunctuation() {
        // "baz foo.bar" cursor at 8 -> should go to 4
        let result = WordMotion.prevWordStart(in: "baz foo.bar", from: 8, bigWord: true)
        XCTAssertEqual(result, 4)
    }

    func test_b_atStartOfLine_returnsNil() {
        let result = WordMotion.prevWordStart(in: "hello", from: 0, bigWord: false)
        XCTAssertNil(result)
    }

    // MARK: - e motion (word end)

    func test_e_simpleWords() {
        // "hello world" cursor at 0 -> should go to 4
        let result = WordMotion.nextWordEnd(in: "hello world", from: 0, bigWord: false)
        XCTAssertEqual(result, 4)
    }

    func test_e_alreadyAtEnd_goesToNextWordEnd() {
        // "hello world" cursor at 4 -> should go to 10
        let result = WordMotion.nextWordEnd(in: "hello world", from: 4, bigWord: false)
        XCTAssertEqual(result, 10)
    }

    func test_e_punctuationBoundary() {
        // "foo.bar" cursor at 0 -> should go to 2
        let result = WordMotion.nextWordEnd(in: "foo.bar", from: 0, bigWord: false)
        XCTAssertEqual(result, 2)
    }

    func test_E_skipsPunctuation() {
        // "foo.bar baz" cursor at 0 -> should go to 6
        let result = WordMotion.nextWordEnd(in: "foo.bar baz", from: 0, bigWord: true)
        XCTAssertEqual(result, 6)
    }

    // MARK: - ge motion (previous word end)

    func test_ge_simpleWords() {
        // "hello world" cursor at 6 -> should go to 4
        let result = WordMotion.prevWordEnd(in: "hello world", from: 6, bigWord: false)
        XCTAssertEqual(result, 4)
    }

    func test_ge_punctuationBoundary() {
        // "foo.bar" cursor at 4 -> should go to 3
        let result = WordMotion.prevWordEnd(in: "foo.bar", from: 4, bigWord: false)
        XCTAssertEqual(result, 3)
    }

    func test_ge_fromMidWord() {
        // "hello world" cursor at 8 ('r') -> should go to 4 ('o' in "hello")
        let result = WordMotion.prevWordEnd(in: "hello world", from: 8, bigWord: false)
        XCTAssertEqual(result, 4)
    }

    func test_ge_atStartOfLine_returnsNil() {
        let result = WordMotion.prevWordEnd(in: "hello", from: 0, bigWord: false)
        XCTAssertNil(result)
    }

    // MARK: - Edge cases

    func test_w_multipleSpaces() {
        // "foo   bar" cursor at 0 -> should go to 6
        let result = WordMotion.nextWordStart(in: "foo   bar", from: 0, bigWord: false)
        XCTAssertEqual(result, 6)
    }

    func test_w_emptyString() {
        let result = WordMotion.nextWordStart(in: "", from: 0, bigWord: false)
        XCTAssertNil(result)
    }

    func test_w_allWhitespace() {
        let result = WordMotion.nextWordStart(in: "     ", from: 0, bigWord: false)
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WordMotionTests 2>&1 | tail -10`
Expected: Compilation errors (WordMotion doesn't exist yet)

- [ ] **Step 3: Implement WordMotion**

```swift
// Mistty/Models/WordMotion.swift
import Foundation

enum WordMotion {

    enum CharClass: Equatable {
        case keyword
        case punctuation
        case whitespace
    }

    static func charClass(_ c: Character) -> CharClass {
        if c.isWhitespace { return .whitespace }
        if c.isLetter || c.isNumber || c == "_" { return .keyword }
        return .punctuation
    }

    private static func bigWordClass(_ c: Character) -> CharClass {
        c.isWhitespace ? .whitespace : .keyword
    }

    private static func classify(_ c: Character, bigWord: Bool) -> CharClass {
        bigWord ? bigWordClass(c) : charClass(c)
    }

    /// w/W: move to start of next word. Returns nil if at end of line.
    static func nextWordStart(in line: String, from col: Int, bigWord: Bool) -> Int? {
        let chars = Array(line)
        guard col < chars.count else { return nil }

        var i = col
        let startClass = classify(chars[i], bigWord: bigWord)

        // Step 1: skip current word (same class)
        while i < chars.count && classify(chars[i], bigWord: bigWord) == startClass {
            i += 1
        }

        // Step 2: skip whitespace
        while i < chars.count && chars[i].isWhitespace {
            i += 1
        }

        return i < chars.count ? i : nil
    }

    /// b/B: move to start of previous word. Returns nil if at start of line.
    static func prevWordStart(in line: String, from col: Int, bigWord: Bool) -> Int? {
        let chars = Array(line)
        guard col > 0 else { return nil }

        var i = col - 1

        // Step 1: skip whitespace
        while i >= 0 && chars[i].isWhitespace {
            i -= 1
        }
        guard i >= 0 else { return nil }

        // Step 2: skip current word (same class) backward
        let wordClass = classify(chars[i], bigWord: bigWord)
        while i > 0 && classify(chars[i - 1], bigWord: bigWord) == wordClass {
            i -= 1
        }

        return i
    }

    /// e/E: move to end of current/next word. Returns nil if at end of line.
    static func nextWordEnd(in line: String, from col: Int, bigWord: Bool) -> Int? {
        let chars = Array(line)
        guard col < chars.count else { return nil }

        var i = col + 1  // Move at least one position
        guard i < chars.count else { return nil }

        // Step 1: skip whitespace
        while i < chars.count && chars[i].isWhitespace {
            i += 1
        }
        guard i < chars.count else { return nil }

        // Step 2: advance through current word
        let wordClass = classify(chars[i], bigWord: bigWord)
        while i + 1 < chars.count && classify(chars[i + 1], bigWord: bigWord) == wordClass {
            i += 1
        }

        return i
    }

    /// ge/gE: move to end of previous word. Returns nil if at start of line.
    static func prevWordEnd(in line: String, from col: Int, bigWord: Bool) -> Int? {
        let chars = Array(line)
        guard col > 0 else { return nil }

        var i = col - 1

        // Step 1: if we're inside a word, skip backward through the current word first
        if !chars[i].isWhitespace {
            let startClass = classify(chars[i], bigWord: bigWord)
            while i > 0 && classify(chars[i - 1], bigWord: bigWord) == startClass {
                i -= 1
            }
            // Now at the start of current word. Move back one more to get past it.
            i -= 1
        }

        guard i >= 0 else { return nil }

        // Step 2: skip whitespace
        while i >= 0 && chars[i].isWhitespace {
            i -= 1
        }
        guard i >= 0 else { return nil }

        // At end of the previous word
        return i
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WordMotionTests 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/WordMotion.swift MisttyTests/Models/WordMotionTests.swift
git commit -m "feat(copy-mode): add WordMotion with vim-exact word/WORD boundary detection"
```

### Task 6: Wire word motions into CopyModeState

**Files:**
- Modify: `Mistty/Models/CopyModeState.swift`
- Modify: `MisttyTests/Models/CopyModeStateTests.swift`

Replace the 5-char jump placeholders with real word motions using `WordMotion` and the `lineReader`.

- [ ] **Step 1: Add tests for word motions in CopyModeState**

Add to CopyModeStateTests:

```swift
// MARK: - Word motions

func test_w_movesToNextWord() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 6)
}

func test_W_movesToNextWORD() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "foo.bar baz" }
    _ = state.handleKey(key: "W", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 8)
}

func test_b_movesToPrevWord() {
    var state = makeState(cursorCol: 6)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "b", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 0)
}

func test_e_movesToWordEnd() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "e", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 4)
}

func test_ge_movesToPrevWordEnd() {
    var state = makeState(cursorCol: 6)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "e", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 4)
}

func test_w_crossLine() {
    var state = makeState(rows: 24, cols: 80, cursorRow: 5, cursorCol: 3)
    let reader: (Int) -> String? = { row in
        row == 5 ? "hello" : "world foo"
    }
    // Cursor at col 3 in "hello", w should go to end, then wrap to next line col 0
    // From col 3, next word start in "hello" -> nil (only one word), so wrap
    _ = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: reader)
    // From col 3 in "hello": skip "lo" to end, no more words -> go to next line
    XCTAssertEqual(state.cursorRow, 6)
    XCTAssertEqual(state.cursorCol, 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CopyModeStateTests 2>&1 | tail -10`
Expected: word motion tests fail (still using 5-char jumps)

- [ ] **Step 3: Replace word motion placeholders in handleNormalKey**

In `CopyModeState.swift`, replace the word motion cases in `handleNormalKey` and add the `handlePendingG` cases:

```swift
// In handleNormalKey, replace the w/b/e/W/B/E cases:
case "w": return wordMotion(count: count, lineReader: lineReader) { line, col in WordMotion.nextWordStart(in: line, from: col, bigWord: false) }
case "W": return wordMotion(count: count, lineReader: lineReader) { line, col in WordMotion.nextWordStart(in: line, from: col, bigWord: true) }
case "b": return wordMotionBackward(count: count, lineReader: lineReader) { line, col in WordMotion.prevWordStart(in: line, from: col, bigWord: false) }
case "B": return wordMotionBackward(count: count, lineReader: lineReader) { line, col in WordMotion.prevWordStart(in: line, from: col, bigWord: true) }
case "e": return wordMotion(count: count, lineReader: lineReader) { line, col in WordMotion.nextWordEnd(in: line, from: col, bigWord: false) }
case "E": return wordMotion(count: count, lineReader: lineReader) { line, col in WordMotion.nextWordEnd(in: line, from: col, bigWord: true) }
```

In `handlePendingG`, replace the ge/gE placeholders:

```swift
case "e":
    let count = pendingCount ?? 1
    pendingCount = nil
    return wordMotionBackward(count: count, lineReader: lineReader) { line, col in WordMotion.prevWordEnd(in: line, from: col, bigWord: false) }
case "E":
    let count = pendingCount ?? 1
    pendingCount = nil
    return wordMotionBackward(count: count, lineReader: lineReader) { line, col in WordMotion.prevWordEnd(in: line, from: col, bigWord: true) }
```

Add the word motion helpers:

```swift
// MARK: - Word motion helpers

/// Execute a forward word motion with cross-line wrapping.
/// After wrapping, re-invokes the motion on the new line so that e/E lands
/// at the word end (not the word start).
private mutating func wordMotion(
    count: Int,
    lineReader: (Int) -> String?,
    motion: (String, Int) -> Int?
) -> [CopyModeAction] {
    for _ in 0..<count {
        guard let line = lineReader(cursorRow) else { break }
        if let newCol = motion(line, cursorCol) {
            cursorCol = newCol
        } else {
            // Wrap to next line
            if cursorRow < rows - 1 {
                cursorRow += 1
                cursorCol = 0
                // Re-invoke the motion on the new line to find the correct position
                // (e.g., e/E needs to find word end, not word start)
                if let nextLine = lineReader(cursorRow) {
                    // First skip leading whitespace
                    let chars = Array(nextLine)
                    var i = 0
                    while i < chars.count && chars[i].isWhitespace { i += 1 }
                    if i < chars.count {
                        // Try the motion from the start of the first word
                        if let motionResult = motion(nextLine, max(0, i - 1)) {
                            cursorCol = motionResult
                        } else {
                            cursorCol = i
                        }
                    }
                }
            }
        }
    }
    return motionActions()
}

/// Execute a backward word motion with cross-line wrapping
private mutating func wordMotionBackward(
    count: Int,
    lineReader: (Int) -> String?,
    motion: (String, Int) -> Int?
) -> [CopyModeAction] {
    for _ in 0..<count {
        guard let line = lineReader(cursorRow) else { break }
        if let newCol = motion(line, cursorCol) {
            cursorCol = newCol
        } else {
            // Wrap to previous line
            if cursorRow > 0 {
                cursorRow -= 1
                if let prevLine = lineReader(cursorRow) {
                    cursorCol = max(0, prevLine.count - 1)
                } else {
                    cursorCol = 0
                }
            }
        }
    }
    return motionActions()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CopyModeStateTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/CopyModeState.swift MisttyTests/Models/CopyModeStateTests.swift
git commit -m "feat(copy-mode): wire real word motions into state machine"
```

---

## Chunk 3: Number Prefixes, f/F/t/T, and Integration Tests

### Task 7: Add integration tests for number prefixes and f/F/t/T

**Files:**
- Create: `MisttyTests/Models/CopyModeIntegrationTests.swift`

- [ ] **Step 1: Write tests for compound inputs**

```swift
// MisttyTests/Models/CopyModeIntegrationTests.swift
import XCTest
@testable import Mistty

final class CopyModeIntegrationTests: XCTestCase {

    private func makeState(rows: Int = 24, cols: Int = 80, cursorRow: Int? = nil, cursorCol: Int? = nil) -> CopyModeState {
        CopyModeState(rows: rows, cols: cols, cursorRow: cursorRow, cursorCol: cursorCol)
    }

    private let emptyLineReader: (Int) -> String? = { _ in nil }

    // MARK: - Number prefixes

    func test_countMovement_5j() {
        var state = makeState(cursorRow: 10)
        // Type "5" then "j"
        _ = state.handleKey(key: "5", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorRow, 15)
    }

    func test_countMovement_10l() {
        var state = makeState(cursorCol: 0)
        _ = state.handleKey(key: "1", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "0", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "l", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorCol, 10)
    }

    func test_0_withoutCount_isLineStart() {
        var state = makeState(cursorCol: 40)
        _ = state.handleKey(key: "0", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorCol, 0)
    }

    func test_5G_goesToLine5() {
        var state = makeState(cursorRow: 10)
        _ = state.handleKey(key: "5", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "G", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.cursorRow, 4) // 0-indexed
    }

    func test_3w_movesThreeWords() {
        var state = makeState(cursorCol: 0)
        let reader: (Int) -> String? = { _ in "one two three four" }
        _ = state.handleKey(key: "3", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: reader)
        XCTAssertEqual(state.cursorCol, 14) // "four"
    }

    // MARK: - f/F/t/T

    func test_f_findsCharForward() {
        var state = makeState(cursorCol: 0)
        let reader: (Int) -> String? = { _ in "hello world" }
        _ = state.handleKey(key: "f", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "o", keyCode: 0, modifiers: [], lineReader: reader)
        XCTAssertEqual(state.cursorCol, 4) // first 'o' in "hello"
    }

    func test_F_findsCharBackward() {
        var state = makeState(cursorCol: 10)
        let reader: (Int) -> String? = { _ in "hello world" }
        _ = state.handleKey(key: "F", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "l", keyCode: 0, modifiers: [], lineReader: reader)
        XCTAssertEqual(state.cursorCol, 9) // 'l' in "world"
    }

    func test_t_stopsBeforeChar() {
        var state = makeState(cursorCol: 0)
        let reader: (Int) -> String? = { _ in "hello world" }
        _ = state.handleKey(key: "t", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: reader)
        XCTAssertEqual(state.cursorCol, 5) // one before 'w' at col 6
    }

    func test_semicolon_repeatsFind() {
        var state = makeState(cursorCol: 0)
        let reader: (Int) -> String? = { _ in "abacada" }
        _ = state.handleKey(key: "f", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "a", keyCode: 0, modifiers: [], lineReader: reader)
        XCTAssertEqual(state.cursorCol, 2) // second 'a'

        _ = state.handleKey(key: ";", keyCode: 0, modifiers: [], lineReader: reader)
        XCTAssertEqual(state.cursorCol, 4) // third 'a'
    }

    func test_comma_reversesFind() {
        var state = makeState(cursorCol: 0)
        let reader: (Int) -> String? = { _ in "abacada" }
        _ = state.handleKey(key: "f", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "a", keyCode: 0, modifiers: [], lineReader: reader)
        _ = state.handleKey(key: ";", keyCode: 0, modifiers: [], lineReader: reader)
        XCTAssertEqual(state.cursorCol, 4)

        _ = state.handleKey(key: ",", keyCode: 0, modifiers: [], lineReader: reader)
        XCTAssertEqual(state.cursorCol, 2)
    }

    func test_3fa_findsThirdOccurrence() {
        var state = makeState(cursorCol: 0)
        let reader: (Int) -> String? = { _ in "xaxaxax" }
        _ = state.handleKey(key: "3", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "f", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "a", keyCode: 0, modifiers: [], lineReader: reader)
        XCTAssertEqual(state.cursorCol, 5) // third 'a'
    }

    // MARK: - Visual mode switching

    func test_V_entersVisualLine() {
        var state = makeState()
        _ = state.handleKey(key: "V", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.subMode, .visualLine)
    }

    func test_ctrlV_entersVisualBlock() {
        var state = makeState()
        _ = state.handleKey(key: "v", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
        XCTAssertEqual(state.subMode, .visualBlock)
    }

    func test_v_inVisualLine_switchesToVisual() {
        var state = makeState()
        _ = state.handleKey(key: "V", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.subMode, .visual)
        XCTAssertNotNil(state.anchor) // anchor preserved
    }

    func test_V_inVisualLine_returnsToNormal() {
        var state = makeState()
        _ = state.handleKey(key: "V", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "V", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertEqual(state.subMode, .normal)
        XCTAssertNil(state.anchor)
    }

    // MARK: - g? help toggle

    func test_gQuestion_togglesHelp() {
        var state = makeState()
        _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        let actions = state.handleKey(key: "?", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertTrue(state.showingHelp)
        XCTAssertTrue(actions.contains(.showHelp))
    }

    func test_helpDismissedByAnyKey() {
        var state = makeState()
        // Show help
        _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        _ = state.handleKey(key: "?", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertTrue(state.showingHelp)

        // Any key dismisses and is consumed
        let actions = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
        XCTAssertFalse(state.showingHelp)
        XCTAssertTrue(actions.contains(.hideHelp))
        // Cursor should NOT have moved (key consumed)
        XCTAssertEqual(state.cursorRow, 23)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter CopyModeIntegrationTests 2>&1 | tail -15`
Expected: All tests pass (these features are already implemented in the state machine from Tasks 2-6)

- [ ] **Step 3: Fix any failing tests**

If any tests fail, investigate and fix the implementation. All features tested here should already be implemented from Tasks 2-6.

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add MisttyTests/Models/CopyModeIntegrationTests.swift Mistty/Models/CopyModeState.swift
git commit -m "test(copy-mode): add integration tests for count prefixes, f/t motions, visual modes"
```

---

## Chunk 4: Visual Line/Block Selection Rendering and Help Overlay

### Task 8: Update SelectionHighlightView for line and block modes

**Files:**
- Modify: `Mistty/Views/Terminal/CopyModeOverlay.swift`

- [ ] **Step 1: Refactor SelectionHighlightView to accept selection mode**

Replace the `SelectionHighlightView` struct:

```swift
struct SelectionHighlightView: View {
    let start: (row: Int, col: Int)
    let end: (row: Int, col: Int)
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let mode: CopySubMode
    let lineReader: ((Int) -> String?)?

    var body: some View {
        Canvas { context, size in
            let minRow = min(start.row, end.row)
            let maxRow = max(start.row, end.row)

            switch mode {
            case .visual:
                drawCharacterWise(context: context, size: size, minRow: minRow, maxRow: maxRow)
            case .visualLine:
                drawLineWise(context: context, size: size, minRow: minRow, maxRow: maxRow)
            case .visualBlock:
                drawBlockWise(context: context, size: size, minRow: minRow, maxRow: maxRow)
            default:
                break
            }
        }
    }

    private func drawCharacterWise(context: GraphicsContext, size: CGSize, minRow: Int, maxRow: Int) {
        for row in minRow...maxRow {
            let x0: CGFloat
            let x1: CGFloat
            if row == minRow && row == maxRow {
                x0 = CGFloat(min(start.col, end.col)) * cellWidth
                x1 = CGFloat(max(start.col, end.col) + 1) * cellWidth
            } else if row == minRow {
                let startCol = start.row <= end.row ? start.col : end.col
                x0 = CGFloat(startCol) * cellWidth
                x1 = size.width
            } else if row == maxRow {
                let endCol = start.row <= end.row ? end.col : start.col
                x0 = 0
                x1 = CGFloat(endCol + 1) * cellWidth
            } else {
                x0 = 0
                x1 = size.width
            }
            let rect = CGRect(x: x0, y: CGFloat(row) * cellHeight, width: x1 - x0, height: cellHeight)
            context.fill(Path(rect), with: .color(.blue.opacity(0.3)))
        }
    }

    private func drawLineWise(context: GraphicsContext, size: CGSize, minRow: Int, maxRow: Int) {
        for row in minRow...maxRow {
            let lineLen = lineReader?(row)?.count ?? 0
            let x1 = lineLen > 0 ? CGFloat(lineLen) * cellWidth : size.width
            let rect = CGRect(x: 0, y: CGFloat(row) * cellHeight, width: x1, height: cellHeight)
            context.fill(Path(rect), with: .color(.blue.opacity(0.3)))
        }
    }

    private func drawBlockWise(context: GraphicsContext, size: CGSize, minRow: Int, maxRow: Int) {
        let minCol = min(start.col, end.col)
        let logicalRightCol = max(start.col, end.col)

        for row in minRow...maxRow {
            let lineLen = lineReader?(row)?.count ?? 0
            let rightCol = max(logicalRightCol, lineLen > 0 ? lineLen - 1 : 0)
            let x0 = CGFloat(minCol) * cellWidth
            let x1 = CGFloat(rightCol + 1) * cellWidth
            let rect = CGRect(x: x0, y: CGFloat(row) * cellHeight, width: x1 - x0, height: cellHeight)
            context.fill(Path(rect), with: .color(.blue.opacity(0.3)))
        }
    }
}
```

- [ ] **Step 2: Update CopyModeOverlay to pass mode and lineReader**

Update the `CopyModeOverlay` struct to accept a `lineReader` and pass it through:

```swift
struct CopyModeOverlay: View {
    let state: CopyModeState
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    var gridOffsetX: CGFloat = 0
    var gridOffsetY: CGFloat = 0
    var lineReader: ((Int) -> String?)? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Selection highlight
            if let range = state.selectionRange {
                SelectionHighlightView(
                    start: range.start,
                    end: range.end,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    mode: state.subMode,
                    lineReader: lineReader
                )
                .offset(x: gridOffsetX, y: gridOffsetY)
            }

            // Cursor
            Rectangle()
                .fill(Color.yellow.opacity(0.7))
                .frame(width: cellWidth, height: cellHeight)
                .offset(
                    x: gridOffsetX + CGFloat(state.cursorCol) * cellWidth,
                    y: gridOffsetY + CGFloat(state.cursorRow) * cellHeight
                )

            // Mode indicator
            VStack {
                Spacer()
                HStack {
                    if state.subMode == .search {
                        Text("/\(state.searchQuery)█")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    } else {
                        Text(modeIndicatorText)
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
        }
        .allowsHitTesting(false)
    }

    private var modeIndicatorText: String {
        switch state.subMode {
        case .normal: return "-- COPY --"
        case .visual: return "-- VISUAL --"
        case .visualLine: return "-- VISUAL LINE --"
        case .visualBlock: return "-- VISUAL BLOCK --"
        case .search: return ""
        }
    }
}
```

- [ ] **Step 3: Update PaneView to pass lineReader**

In `PaneView.swift`, update the copy mode overlay construction to pass a `lineReader` closure. Add a `lineReader` property:

```swift
var lineReader: ((Int) -> String?)? = nil
```

And pass it in the overlay:

```swift
CopyModeOverlay(
    state: state,
    cellWidth: cellW,
    cellHeight: cellH,
    gridOffsetX: offX,
    gridOffsetY: offY,
    lineReader: lineReader
)
```

Construct the lineReader inline in PaneView using the pane's surface access. Replace the copy mode overlay section in PaneView's body:

```swift
.overlay {
    if let state = copyModeState {
        GeometryReader { geo in
            let metrics = pane.surfaceView.gridMetrics()
            let cellW = metrics?.cellWidth ?? geo.size.width / CGFloat(state.cols)
            let cellH = metrics?.cellHeight ?? geo.size.height / CGFloat(state.rows)
            let offX = metrics?.offsetX ?? 0
            let offY = metrics?.offsetY ?? 0
            let reader: ((Int) -> String?)? = { row in
                guard let surface = pane.surfaceView.surface else { return nil }
                let size = ghostty_surface_size(surface)
                var sel = ghostty_selection_s()
                sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
                sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
                sel.top_left.x = 0
                sel.top_left.y = UInt32(row)
                sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
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
            CopyModeOverlay(
                state: state,
                cellWidth: cellW,
                cellHeight: cellH,
                gridOffsetX: offX,
                gridOffsetY: offY,
                lineReader: reader
            )
        }
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/Terminal/CopyModeOverlay.swift Mistty/Views/Terminal/PaneView.swift
git commit -m "feat(copy-mode): add visual line and block selection rendering"
```

### Task 9: Create help overlay view

**Files:**
- Create: `Mistty/Views/Terminal/CopyModeHelpOverlay.swift`
- Modify: `Mistty/Views/Terminal/CopyModeOverlay.swift`

- [ ] **Step 1: Create CopyModeHelpOverlay**

```swift
// Mistty/Views/Terminal/CopyModeHelpOverlay.swift
import SwiftUI

struct CopyModeHelpOverlay: View {
    private let navHints: [(key: String, label: String)] = [
        ("h/j/k/l", "move cursor"),
        ("w/b/e", "word fwd/back/end"),
        ("W/B/E", "WORD motions"),
        ("ge/gE", "end of prev word/WORD"),
        ("0/$", "line start/end"),
        ("g/G", "top/bottom"),
        ("[count]", "repeat motion"),
    ]

    private let selectionHints: [(key: String, label: String)] = [
        ("v", "visual"),
        ("V", "visual line"),
        ("Ctrl-v", "visual block"),
        ("Esc", "exit visual"),
    ]

    private let findHints: [(key: String, label: String)] = [
        ("f/F", "find char"),
        ("t/T", "find before"),
        (";", "repeat find"),
        (",", "reverse find"),
    ]

    private let actionHints: [(key: String, label: String)] = [
        ("/", "search forward"),
        ("n", "next match"),
        ("y", "yank selection"),
        ("g?", "toggle this help"),
        ("Esc", "exit copy mode"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COPY MODE HELP")
                .font(.system(size: 12, weight: .bold, design: .monospaced))

            HStack(alignment: .top, spacing: 20) {
                hintColumn(title: "Navigation", hints: navHints)
                hintColumn(title: "Selection", hints: selectionHints)
                hintColumn(title: "Find on Line", hints: findHints)
                hintColumn(title: "Actions", hints: actionHints)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(12)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.6), lineWidth: 1)
        )
    }

    private func hintColumn(title: String, hints: [(key: String, label: String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .fontWeight(.bold)
                .padding(.bottom, 2)
            ForEach(hints, id: \.key) { hint in
                HStack(spacing: 6) {
                    Text(hint.key)
                        .frame(minWidth: 60, alignment: .trailing)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 2))
                    Text(hint.label)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add help overlay to CopyModeOverlay**

In `CopyModeOverlay.swift`, add the help overlay display inside the ZStack, after the mode indicator:

```swift
// Help overlay (g?)
if state.showingHelp {
    CopyModeHelpOverlay()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Mistty/Views/Terminal/CopyModeHelpOverlay.swift Mistty/Views/Terminal/CopyModeOverlay.swift
git commit -m "feat(copy-mode): add toggle-able help overlay (g?)"
```

### Task 10: Update yankSelection for visual line and block modes

**Files:**
- Modify: `Mistty/App/ContentView.swift`

The existing `yankSelection` reads text using a single ghostty selection. For line and block modes, we need to adjust the selection coordinates.

- [ ] **Step 1: Update yankSelection to handle all visual modes**

Replace the `yankSelection` method in ContentView:

```swift
private func yankSelection() {
    guard let tab = store.activeSession?.activeTab,
          let pane = tab.activePane,
          let state = tab.copyModeState,
          let anchor = state.anchor,
          let surface = pane.surfaceView.surface
    else { return }

    let size = ghostty_surface_size(surface)
    let cols = Int(size.columns)
    var textToCopy: String?

    switch state.subMode {
    case .visual:
        // Character-wise: read from anchor to cursor
        textToCopy = readGhosttyText(
            surface: surface,
            startRow: anchor.row, startCol: anchor.col,
            endRow: state.cursorRow, endCol: state.cursorCol,
            rectangle: false
        )

    case .visualLine:
        // Line-wise: full lines from min to max row
        let minRow = min(anchor.row, state.cursorRow)
        let maxRow = max(anchor.row, state.cursorRow)
        textToCopy = readGhosttyText(
            surface: surface,
            startRow: minRow, startCol: 0,
            endRow: maxRow, endCol: cols - 1,
            rectangle: false
        )

    case .visualBlock:
        // Block-wise: read each row's slice, joined by newlines
        let minRow = min(anchor.row, state.cursorRow)
        let maxRow = max(anchor.row, state.cursorRow)
        let minCol = min(anchor.col, state.cursorCol)
        var lines: [String] = []
        for row in minRow...maxRow {
            if let line = readTerminalLine(row: row) {
                let chars = Array(line)
                let rightCol = max(max(anchor.col, state.cursorCol), chars.count > 0 ? chars.count - 1 : 0)
                let start = min(minCol, chars.count)
                let end = min(rightCol + 1, chars.count)
                if start < end {
                    lines.append(String(chars[start..<end]))
                } else {
                    lines.append("")
                }
            }
        }
        textToCopy = lines.joined(separator: "\n")

    default:
        return
    }

    if let text = textToCopy, !text.isEmpty {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private func readGhosttyText(
    surface: OpaquePointer,
    startRow: Int, startCol: Int,
    endRow: Int, endCol: Int,
    rectangle: Bool
) -> String? {
    var sel = ghostty_selection_s()
    sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
    sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
    sel.top_left.x = UInt32(startCol)
    sel.top_left.y = UInt32(startRow)
    sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
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

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat(copy-mode): update yankSelection for visual line and block modes"
```

### Task 11: Run all tests and verify build

**Files:** None (verification only)

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 2: Run formatter**

Run: `just fmt`

- [ ] **Step 3: Verify clean build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds with no warnings

- [ ] **Step 4: Final commit if formatter made changes**

```bash
git add -A
git commit -m "style: format copy mode changes"
```
