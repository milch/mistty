# Copy Mode Phase 1: Motion & Selection Improvements

## Overview

Phase 1 of copy mode improvements focuses on vim-faithful motion commands, proper visual selection modes, and a help overlay. This builds on the existing `CopyModeState` struct and `NSEvent` monitor architecture without requiring scrollback access or new ghostty APIs.

Phases 2 (scrollback + search improvements) and 3 (yank mode) are out of scope for this spec.

## Architecture: State Machine with Action-Based Key Handling

### Sub-Mode Enum

```swift
enum CopySubMode {
    case normal
    case visual        // character-wise (v)
    case visualLine    // line-wise (V)
    case visualBlock   // block-wise (Ctrl-v)
    case search        // existing search mode
}
```

### Action-Based Design

`CopyModeState` becomes a self-contained state machine. Instead of ContentView interpreting keys and mutating state directly, all key handling moves into the state struct:

```swift
enum CopyModeAction {
    case cursorMoved          // signals UI refresh; new position already in state
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
    // no .none -- return an empty array instead
}

mutating func handleKey(
    key: Character,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    lineReader: (Int) -> String?
) -> [CopyModeAction]
```

The `lineReader` closure provides access to terminal content. ContentView supplies it by wrapping `ghostty_surface_read_text()`. This keeps the state machine testable with mock line content.

Returns an array of actions since one keypress can trigger multiple effects (e.g., movement + selection update). An empty array means the key was consumed with no side effects.

**Key extraction:** The `key` parameter should come from `event.charactersIgnoringModifiers` (not `event.characters`) so that modifier combinations resolve correctly. For example, Ctrl-v produces a control character in `event.characters`, but `charactersIgnoringModifiers` still yields `v`, which combined with checking `modifiers.contains(.control)` allows correct detection of Ctrl-v for visual block mode.

### Pending Input State

```swift
var pendingCount: Int?                                    // digit accumulator for number prefixes
var pendingFindChar: FindCharKind?                        // set when f/F/t/T pressed, awaiting target char
var lastFind: (kind: FindCharKind, char: Character)?      // for ; and , repeat
var pendingG: Bool                                        // set when g pressed, awaiting second key
var showingHelp: Bool                                     // toggled by ?
```

### Escape Behavior (tmux-style)

- In `visual`/`visualLine`/`visualBlock`: returns `enterSubMode(.normal)` (clears selection, stays in copy mode)
- In `normal`: returns `exitCopyMode`
- In `search`: returns `cancelSearch` + `enterSubMode(.normal)`

## Word Motions

### Character Classes (small-word: w/e/b/ge)

1. **Keyword:** letters, digits, underscore
2. **Punctuation:** non-blank, non-keyword characters
3. **Whitespace:** spaces, tabs

Word boundaries occur at transitions between these classes. A "word" is a contiguous run of keyword chars OR a contiguous run of punctuation chars.

### WORD Classes (W/E/B/gE)

Two classes only: blank and non-blank. A WORD is any contiguous run of non-blank characters.

### Motion Definitions

| Key | Motion |
|-----|--------|
| w/W | Move to start of next word/WORD |
| e/E | Move to end of current/next word/WORD |
| b/B | Move to start of current/previous word/WORD |
| ge/gE | Move to end of previous word/WORD |

### Cross-Line Behavior

Word motions wrap across lines. If `w` reaches end of line, it continues to the first word on the next line via `lineReader`. Same for `b` going backwards. Matches vim behavior.

**Phase 1 viewport limitation:** Wrapping stops at viewport boundaries (row 0 and row `rows-1`). Scrollback wrapping is deferred to Phase 2.

### Pending g Resolution

When `g` is pressed, `pendingG` is set to `true`. The next key resolves it:

- `e` -> ge motion, `E` -> gE motion
- `g` -> go to top (existing behavior)
- `0` -> cancels pending g, then executes line-start (since `0` without pending count is line-start)
- Any other key: cancels pending g, then the key is processed normally (e.g., `g` then `f` cancels pending g and starts a find-char)

## f/F/t/T and ;/,

### Find-Character Flow

1. User presses f/F/t/T -> `pendingFindChar` set to the kind
2. Next character keypress consumed as target character
3. Scan current line text (via `lineReader`) from cursor position:
   - **f:** forward, cursor lands ON the match
   - **F:** backward, cursor lands ON the match
   - **t:** forward, cursor lands one col BEFORE match
   - **T:** backward, cursor lands one col AFTER match
4. If not found, no movement
5. `lastFind` stored as `(kind, char)`

### Repeat

- **;** repeats `lastFind` in the same direction
- **,** repeats `lastFind` in the opposite direction (f<->F, t<->T)
- If no `lastFind` exists, no-op

### Number Prefix Interaction

`3fa` finds the 3rd occurrence of `a` forward on the current line.

### Priority with Pending g

f/F/t/T are not valid after `g`, so pressing `g` then `f` cancels the pending g and starts a find-char.

## Number Prefixes

### Movement Multipliers Only

Digits 1-9 start a count, 0-9 continue it. `0` alone maps to line-start (existing behavior) -- it only appends to a count if `pendingCount` is already non-nil.

The count is applied as a multiplier when a movement key arrives. The motion is executed `count` times, then `pendingCount` is cleared.

Applies to: h/j/k/l, w/W/b/B/e/E, ge/gE, f/F/t/T, ;/,, G (as go-to-line).

`5G` goes to line 5. `G` without count goes to bottom (existing).

## Visual Line & Visual Block Modes

### Visual Line Mode (V)

- Selection always covers full lines from column 0 to the end of each line's text content
- Anchor is the line where V was pressed
- Selection spans from anchor line to cursor line, inclusive
- Horizontal movement still moves the cursor (for when exiting back to normal) but highlight shows full lines

### Visual Block Mode (Ctrl-v)

- Defined by anchor point and cursor position
- Left edge: `min(anchorCol, cursorCol)`
- Right edge per row: `max(cursorCol, length of that row's text)`
- Row range: `min(anchorRow, cursorRow)` to `max(anchorRow, cursorRow)`
- The right edge can be ragged per-line

### Selection State

Selection is derived from the sub-mode rather than stored as a separate `isSelecting` flag:

- `normal` -> no selection
- `visual` -> character-wise from anchor to cursor (existing behavior)
- `visualLine` -> full lines from anchor line to cursor line
- `visualBlock` -> rectangular from anchor corner to cursor, with per-row right edge

Entering any visual sub-mode always sets the anchor to the current cursor position. The anchor stays fixed until the mode is exited.

### Mode Switching Between Visual Modes

- Pressing `v` in `visualLine`/`visualBlock` -> switches to `visual` (keeps anchor)
- Pressing `V` in `visual`/`visualBlock` -> switches to `visualLine` (keeps anchor)
- Pressing `Ctrl-v` in `visual`/`visualLine` -> switches to `visualBlock` (keeps anchor)
- Pressing the same key as current mode -> back to `normal` (clears selection)

### Yank Behavior

- Character-wise: copies text from anchor to cursor (existing)
- Line-wise: copies full lines including newlines
- Block-wise: copies each row's slice within the column range, joined by newlines

### Yank Without Selection

`y` in normal sub-mode (no active selection) is a no-op.

## Help Overlay

### Activation

`?` in normal sub-mode toggles `showingHelp`. Any other keypress while help is visible hides it and is consumed (does not execute). Escape also hides it.

**Note:** In vim, `?` is reverse search. Reverse search is planned for Phase 2. At that point, `?` will be reassigned to reverse search and help will move to a different key (TBD in Phase 2 spec).

### Rendering

Centered overlay on top of the terminal. Semi-transparent dark background, rounded border, monospace text. Similar to window mode's toast but larger.

### Content

Organized by category:

```
Navigation                Selection              Search
h/j/k/l  move cursor     v      visual          /  search forward
w/b/e    word fwd/back/   V      visual line     n  next match
         end              Ctrl-v visual block
W/B/E    WORD motions     Esc    exit visual     Actions
ge/gE    end of prev                             y  yank selection
         word/WORD        Find on Line           ?  toggle help
0/$      line start/end   f/F    find char       Esc exit copy mode
g/G      top/bottom       t/T    find before
[count]  repeat motion    ;      repeat find
                          ,      reverse find
```

## ContentView Integration

### Simplified Event Monitor

The `NSEvent` monitor closure reduces to:

1. Convert `NSEvent` to `(character, keyCode, modifiers)`
2. Call `state.handleKey(...)` with `lineReader` closure wrapping `ghostty_surface_read_text()`
3. Apply returned actions:
   - `.cursorMoved` -> trigger UI refresh (position already in state)
   - `.updateSelection` -> trigger UI refresh (selection already in state)
   - `.yank` -> write to `NSPasteboard`
   - `.exitCopyMode` -> call existing `exitCopyMode()`
   - `.enterSubMode` -> trigger UI refresh (sub-mode already in state)
   - `.showHelp`/`.hideHelp` -> toggle overlay
   - Search actions -> update search UI state

### Mode Indicator Text

- `normal` -> `-- COPY --`
- `visual` -> `-- VISUAL --`
- `visualLine` -> `-- VISUAL LINE --`
- `visualBlock` -> `-- VISUAL BLOCK --`
- `search` -> `/query_`

### No Changes To

- Copy mode entry/exit lifecycle
- `NSEvent` monitor registration
- Mutual exclusion with window mode

## CopyModeOverlay Rendering Changes

`SelectionHighlightView` handles three selection styles:

- **Character-wise:** existing behavior (start to end, wrapping across lines)
- **Line-wise:** full-width rectangles from min line to max line, each row from col 0 to end of that line's text
- **Block-wise:** per-row rectangles from `minCol` to `max(cursorCol, lineLength)` for each row in range
