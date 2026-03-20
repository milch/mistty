# Copy Mode Phase 2: Scrollback & Search

## Overview

Phase 2 extends copy mode to navigate the full scrollback buffer and adds vim-faithful search with all-match highlighting. Builds on the Phase 1 action-based state machine without changing entry/exit lifecycle.

Phase 1 (motion & selection) is complete. Phase 3 (yank mode) is out of scope for this spec.

## Ghostty API Surface

Phase 2 relies on several ghostty APIs not used in Phase 1:

### Binding Actions for Scrolling

`ghostty_surface_binding_action(surface, actionString, actionStringLength)` provides exact scrolling:

- `"scroll_page_lines:N"` — scroll by exactly N lines (positive = down, negative = up)
- `"scroll_to_top"` — scroll to top of scrollback
- `"scroll_to_bottom"` — scroll to bottom (active area)
- `"scroll_to_row:N"` — scroll to exact row N from top

This avoids the `ghostty_surface_mouse_scroll()` API, which takes pixel/tick deltas affected by user scroll multiplier config. Binding actions give exact row-level control.

### Scrollbar Action for Coordinate Mapping

Ghostty sends `GHOSTTY_ACTION_SCROLLBAR` via the action callback with:

```c
typedef struct {
    uint64_t total;   // total rows in scrollback + active
    uint64_t offset;  // current viewport offset from top of scrollback
    uint64_t len;     // viewport height in rows
} ghostty_action_scrollbar_s;
```

This provides the viewport-to-screen coordinate mapping:

```
screen_row = viewport_row + scrollbar.offset
viewport_row = screen_row - scrollbar.offset
```

ContentView must handle `GHOSTTY_ACTION_SCROLLBAR` in the action callback and store the current scrollbar state. This is needed for:
- Converting between viewport and screen coordinates
- Knowing total scrollback depth for search
- Detecting scroll boundaries (at top/bottom)

### GHOSTTY_POINT_SCREEN for Text Reading

`ghostty_surface_read_text()` with `GHOSTTY_POINT_SCREEN` tag reads from screen coordinates (row 0 = top of scrollback, row `total-1` = bottom of active area). Used for full-scrollback search.

## Scrollback Navigation via Viewport Scrolling

Copy mode scrolls the ghostty viewport when the cursor moves past a viewport edge. Ghostty owns scroll state — `CopyModeState` does not track a scroll offset. ContentView tracks the viewport position via the scrollbar action callback.

### Scroll Triggering

When a motion moves the cursor past row 0 (top) or row `rows-1` (bottom), `handleKey` returns a `.scroll(deltaRows:)` action. ContentView translates this to `ghostty_surface_binding_action(surface, "scroll_page_lines:N", ...)`. The cursor stays at the edge row while the viewport shifts.

Ghostty clamps scrolling at scrollback boundaries naturally.

### New Action

```swift
case scroll(deltaRows: Int)  // positive = down, negative = up
```

### Paging Commands

| Key | Behavior |
|-----|----------|
| Ctrl-D | Scroll down `rows/2` lines, cursor moves down same amount |
| Ctrl-U | Scroll up `rows/2` lines, cursor moves up same amount |
| Ctrl-F | Scroll down `rows` lines (full page) |
| Ctrl-B | Scroll up `rows` lines (full page) |

After paging, the cursor is clamped to content boundaries (last non-whitespace character) as in Phase 1.

Number prefixes apply: `5 Ctrl-D` pages down 5 half-screens.

**Edge case — paging near scrollback boundaries:** When near the top of scrollback, a full Ctrl-U may only scroll partially. After issuing the scroll action, ContentView reads the updated scrollbar state to determine how many rows actually scrolled, then adjusts the cursor position accordingly rather than assuming the full delta was applied.

### All Cross-Line Motions Scroll

Affected motions: j/k, w/W/b/B/e/E/ge/gE, n/N search navigation. When any of these would cross a viewport boundary, scrolling is triggered.

**Implementation note:** The existing `moveUp()`/`moveDown()` helpers currently clamp to `0..<rows` silently. These must be updated to detect boundary hits and return `.scroll` actions instead of clamping. Similarly, word motion helpers that call into the next/previous line must detect viewport edges.

**desiredCol preservation:** `desiredCol` (used for j/k vertical stickiness) is preserved across scroll + continuation cycles since it lives on the state struct and is not cleared by scroll actions.

## Anchor Coordinate Adjustment on Scroll

Visual selection anchors are stored as viewport-relative coordinates. When the viewport scrolls, the anchor must be adjusted to continue referring to the same terminal content.

### Mechanism

When ContentView processes a `.scroll(deltaRows: N)` action, it adjusts the anchor:

```swift
if let anchor = state.anchor {
    state.anchor = (row: anchor.row - deltaRows, col: anchor.col)
}
```

(The anchor is stored as a `(row: Int, col: Int)?` tuple, matching the existing Phase 1 representation.)

Scrolling down by N means content moves up, so the anchor row decreases by N. Scrolling up by N means content moves down, so the anchor row increases by N.

### Anchor Out of Viewport

If the adjusted anchor row falls outside `0..<rows`, the anchor is still valid — it represents content that has scrolled off-screen. Selection rendering handles this by clamping the visible highlight to viewport bounds while the logical selection remains correct for yanking.

### Yank with Off-Screen Anchor

When yanking a selection that spans beyond the viewport, ContentView reads the selected text using `GHOSTTY_POINT_SCREEN` coordinates (computed from the scrollbar offset) rather than viewport coordinates. This ensures the full selection is captured even if the anchor has scrolled off-screen.

## Cross-Line Motion Continuation

Word motions that wrap across a viewport edge need fresh line content after scrolling. This is handled via a continuation pattern.

### Mechanism

1. `handleKey` detects the motion needs to cross a viewport boundary
2. Returns `[.scroll(deltaRows: N), .needsContinuation]`
3. ContentView processes the scroll (via `ghostty_surface_binding_action`)
4. ContentView calls a dedicated `continuePendingMotion(lineReader:)` method on the state
5. The motion completes on the new content

### New Action

```swift
case needsContinuation  // signals ContentView to call continuePendingMotion after scrolling
```

### Continuation API

Rather than re-using `handleKey` (which requires dummy key/modifier parameters), a dedicated method avoids ambiguity:

```swift
mutating func continuePendingMotion(
    lineReader: (Int) -> String?
) -> [CopyModeAction]
```

This method checks `pendingContinuation`, executes the remaining motion, and clears the continuation state. Returns an empty array if no continuation is pending.

### State Machine Purity

The state machine never reads stale content. By returning `.needsContinuation` instead of trying to read post-scroll content directly, the `lineReader` closure always reflects what's actually on screen.

### Continuation State

```swift
var pendingContinuation: ContinuationState?

struct ContinuationState {
    let motion: PendingMotion
    let remaining: Int        // remaining count (e.g., 3 more words to skip)
}

enum PendingMotion {
    case wordForward(bigWord: Bool)       // w/W
    case wordBackward(bigWord: Bool)      // b/B
    case wordEndForward(bigWord: Bool)    // e/E
    case wordEndBackward(bigWord: Bool)   // ge/gE
    case lineDown                         // j
    case lineUp                           // k
}
```

### Failure Case — Scroll Boundary

If `ghostty_surface_binding_action` scrolls but the viewport didn't actually move (already at top/bottom of scrollback), the `lineReader` content hasn't changed. `continuePendingMotion` detects this by comparing the content at the boundary row before and after, and stops the motion rather than looping. The continuation is cleared.

### Escape During Continuation

If the user presses Escape before ContentView calls `continuePendingMotion`, the pending continuation is cleared on the next `handleKey` call (Escape handling checks and clears `pendingContinuation` first).

## Search with Full Scrollback

Search is rebuilt to scan `GHOSTTY_POINT_SCREEN` coordinates. Mistty owns the search implementation entirely (ghostty's built-in search overlay is not used).

### Sub-Mode Changes

```swift
enum CopySubMode {
    case normal
    case visual
    case visualLine
    case visualBlock
    case searchForward   // was: .search
    case searchReverse   // new
}
```

The `isSearching` computed property updates to check both:
```swift
var isSearching: Bool { subMode == .searchForward || subMode == .searchReverse }
```

**Dispatch update:** The existing `handleKey` checks `if subMode == .search` for routing to search key handling. This must change to `if isSearching` to cover both directions. The `handleEscape()` method must also clear `pendingContinuation` in all branches.

### Key Bindings

| Key | Action |
|-----|--------|
| `/` | Enter forward search mode |
| `?` | Enter reverse search mode (add to `handleNormalKey` switch, was unhandled in Phase 1) |
| `n` | Repeat search in original direction (replaces current `.confirmSearch` usage) |
| `N` | Repeat search in opposite direction |
| Return | Confirm search, place cursor on match |
| Escape | Cancel search, return to normal sub-mode |

### New Actions

```swift
case searchNext   // n - repeat in same direction (replaces n returning .confirmSearch)
case searchPrev   // N - repeat in opposite direction
```

### Search Execution

`performSearch()` moves from viewport-only scanning to full scrollback:

1. Read lines using `ghostty_surface_read_text()` with `GHOSTTY_POINT_SCREEN` tag
2. Total scrollback height is known from the stored scrollbar state (`scrollbar.total`)
3. Convert cursor position to screen coordinates: `screen_row = cursor_row + scrollbar.offset`
4. Scan from cursor position in the specified direction (forward or reverse)
5. Wrap around the entire scrollback (forward wraps from bottom to top, reverse wraps from top to bottom)
6. On match: use `ghostty_surface_binding_action(surface, "scroll_to_row:N", ...)` to make the match visible, then set cursor to the match's viewport-relative position
7. Case-insensitive matching (unchanged from Phase 1)

### Search Direction State

```swift
var searchDirection: SearchDirection = .forward  // non-optional, defaults to forward

enum SearchDirection {
    case forward
    case reverse
}
```

Persists after search confirmation so `n`/`N` work in normal sub-mode. `n` uses `searchDirection`, `N` uses the opposite.

### Match Count

On search confirm, scan the entire scrollback for all occurrences to compute total match count. Track which match the cursor is on (1-based index). Update the index when `n`/`N` moves between matches.

```swift
var searchMatchIndex: Int?   // 1-based current match index
var searchMatchTotal: Int?   // total matches in scrollback
```

**Performance:** For large scrollback (10,000+ lines), the full count scan runs asynchronously on a background queue. The mode indicator shows `/query` immediately, then updates to `/query [3/47]` once counting completes. Individual `n`/`N` navigation does not re-count — it increments/decrements the index.

### performSearch Signature Change

```swift
// Old (Phase 1 - in ContentView)
private func performSearch(_ state: inout CopyModeState)

// New (Phase 2 - in ContentView)
private func performSearch(
    _ state: inout CopyModeState,
    direction: SearchDirection,
    screenLineReader: (Int) -> String?,  // reads SCREEN coordinates
    totalScreenRows: Int                  // from scrollbar.total
)
```

### No Incremental Search

Search results are not updated as the user types (no live preview). The search executes on Return/Enter confirmation only, same as Phase 1. Incremental search is a potential future enhancement but out of scope.

## All-Match Highlighting

When a search query is active, `CopyModeOverlay` highlights all visible matches.

### Rendering

On every viewport change (scroll, search navigation), scan all visible lines for occurrences of the search query:

- **Current match:** bright highlight (orange/amber, similar to vim `hlsearch` + `incsearch`)
- **Other visible matches:** dim highlight (semi-transparent yellow)

### Implementation

`CopyModeOverlay` receives the active search query and current match position. It uses `lineReader` (viewport-based) to scan visible lines and renders highlight rectangles using cell geometry from `gridMetrics()`.

```swift
struct SearchHighlightView: View {
    let query: String
    let currentMatchRow: Int?
    let currentMatchCol: Int?
    let lineReader: (Int) -> String?
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let rows: Int
}
```

### Re-scanning

Highlights are recomputed when:
- Viewport scrolls (paging, cursor motion)
- `n`/`N` moves to next/prev match
- Copy mode is exited (highlights cleared)

## Mode Indicator Updates

```
Normal:           -- COPY --
Visual:           -- VISUAL --
Visual Line:      -- VISUAL LINE --
Visual Block:     -- VISUAL BLOCK --
Forward search:   /query  [3/47]
Reverse search:   ?query  [3/47]
```

The `[3/47]` indicator shows current match index and total count. Displayed after search is confirmed and count completes.

## Help Overlay Update

Updated content in `CopyModeHelpOverlay`:

```
Navigation                Selection              Search
h/j/k/l  move cursor     v      visual          /  search forward
w/b/e    word fwd/back/   V      visual line     ?  search backward
         end              Ctrl-v visual block    n  next match
W/B/E    WORD motions     Esc    exit visual     N  prev match
ge/gE    end of prev
         word/WORD        Find on Line           Scrolling
0/$      line start/end   f/F    find char       Ctrl-D half page down
g/G      top/bottom       t/T    find before     Ctrl-U half page up
[count]  repeat motion    ;      repeat find     Ctrl-F full page down
                          ,      reverse find    Ctrl-B full page up

                          g?     toggle this help
                                 Actions
                                 y  yank selection
                                 Esc exit copy mode
```

`?` is reassigned from "toggle help" to "search backward". Help remains accessible via `g?`.

## Scrollbar State Management

### Action Callback Integration

`GhosttyApp.swift`'s `actionCallback` must handle `GHOSTTY_ACTION_SCROLLBAR`:

```swift
case GHOSTTY_ACTION_SCROLLBAR:
    let scrollbar = action.action.scrollbar
    // Route to the appropriate surface/pane and store the scrollbar state
```

### Storage

The scrollbar state is stored on the pane or surface view and made accessible to ContentView:

```swift
struct ScrollbarState {
    var total: UInt64    // total rows
    var offset: UInt64   // viewport offset from top
    var len: UInt64      // viewport height
}
```

Updated whenever the scrollbar action fires (on every scroll event and terminal output).

## Key Changes Summary

### New in CopyModeAction
- `scroll(deltaRows: Int)` — scroll the viewport
- `needsContinuation` — signal ContentView to call `continuePendingMotion`
- `searchNext` — repeat search in same direction
- `searchPrev` — repeat search in opposite direction

### New in CopyModeState
- `pendingContinuation: ContinuationState?` — tracks in-progress cross-boundary motions
- `searchDirection: SearchDirection` — forward or reverse (non-optional, defaults to .forward)
- `searchMatchIndex: Int?` — current match (1-based)
- `searchMatchTotal: Int?` — total matches in scrollback
- `continuePendingMotion(lineReader:)` — dedicated continuation method

### Sub-Mode Changes
- `.search` splits into `.searchForward` and `.searchReverse`
- `isSearching` computed property updated to check both

### ContentView Changes
- `performSearch()` upgraded to scan `GHOSTTY_POINT_SCREEN` coordinates
- Scroll action handler calls `ghostty_surface_binding_action` with `scroll_page_lines`
- Continuation handler calls `continuePendingMotion` with fresh `lineReader`
- New `screenLineReader` closure for full scrollback access
- Anchor adjustment on scroll (row offset by delta)
- Yank with off-screen anchor uses screen coordinates
- `n` returns `.searchNext` instead of `.confirmSearch`

### GhosttyApp Changes
- Action callback handles `GHOSTTY_ACTION_SCROLLBAR`
- Scrollbar state stored and accessible to ContentView

### CopyModeOverlay Changes
- New `SearchHighlightView` for all-match highlighting
- Mode indicator shows `[N/M]` match count during active search

### CopyModeHelpOverlay Changes
- Updated help text with search backward (`?`), `N` for prev match, scrolling section (Ctrl-D/U/F/B)

### No Changes To
- Copy mode entry/exit lifecycle
- NSEvent monitor registration
- Visual mode mechanics (v/V/Ctrl-v)
- f/F/t/T find-character
- Number prefix system
- Help overlay activation (g?)
