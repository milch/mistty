# Post-MVP Phase 1 Design

**Goal:** Make Mistty a viable daily-driver terminal by adding polish (bell, tab rename, preferences), power-user pane management (window mode), and copy mode for scrollback navigation.

**Scope:** Three feature groups, ordered by complexity.

---

## A. Polish & Daily-Driver Readiness

### Bell Indicators

When a background tab or session triggers the bell character (`\a`), show a visual indicator:
- Tab bar: colored dot next to tab title
- Sidebar: colored dot next to session/tab name
- Clear indicator when the tab becomes active (user switches to it)

Implementation: handle `GHOSTTY_ACTION_BELL` in the action callback, post a notification with paneID, set a `hasBell` flag on the tab. Clear on `activeTab` change.

### Tab Rename

Double-click a tab name in the tab bar to enter inline editing mode. Cmd+Shift+R as a keyboard shortcut to rename the active tab.

`MisttyTab.title` already exists and is set by ghostty's SET_TITLE action. A `customTitle` property takes precedence over the auto-detected title when set.

### Preference Pane

A SwiftUI `Settings` scene accessible via Cmd+,. Controls:
- Font size (maps to ghostty config `font-size`)
- Cursor style (block, beam, underline)
- Scrollback lines
- Sidebar default visibility

Reads/writes `~/.config/mistty/config.toml` via existing `MisttyConfig`. Changes require surface recreation or ghostty config reload to take effect.

---

## B. Power-User Pane Management (Window Mode)

### Concept

Cmd+X enters "window mode" — a modal state where keyboard input controls pane layout instead of going to the terminal. A visible indicator (colored border or overlay text) shows the mode is active.

### Keybindings in Window Mode

| Key | Action |
|-----|--------|
| Arrow keys | Navigate to adjacent pane |
| Cmd+Arrow | Resize active split boundary |
| `b` | Break pane out to new tab |
| `m` | Merge: pull adjacent pane into current split |
| `r` | Rotate split direction (H to V) |
| `z` | Zoom/unzoom pane (fullscreen toggle) |
| Escape | Exit window mode |

### Model Changes

- `SplitDirection` rotation: swap `.horizontal` / `.vertical`
- `PaneLayoutNode.split` gains a `ratio: CGFloat` (default 0.5) for resize
- `PaneLayout` gains tree navigation (find parent, find sibling, find adjacent by direction)
- `MisttyTab` gains `isWindowModeActive: Bool` and `zoomedPane: MisttyPane?`

### View Changes

- `PaneLayoutView` renders ratio-aware splits (custom divider or proportional frames)
- Zoom: when `zoomedPane` is set, render only that pane fullscreen, restore on unzoom
- Window mode indicator: orange/yellow border on active pane

---

## D. Copy Mode

### Concept

Cmd+Shift+C (or configurable) enters copy mode — freezes terminal output and allows vim-style navigation through scrollback with visual selection.

### Keybindings in Copy Mode

| Key | Action |
|-----|--------|
| `h/j/k/l` | Move cursor left/down/up/right |
| `w/b` | Jump forward/back by word |
| `0/$` | Start/end of line |
| `g/G` | Top/bottom of scrollback |
| `v` | Toggle visual selection |
| `y` | Yank selection to clipboard |
| `/` | Search forward |
| `n/N` | Next/previous search match |
| Escape | Exit copy mode |

### Architecture

- Read scrollback content from ghostty via `ghostty_surface_inspector` or screen content APIs (requires API spike)
- Overlay SwiftUI view on top of terminal showing cursor position and selection highlight
- `CopyModeState` model tracks cursor position, selection range, search query
- Clipboard write via `NSPasteboard`

### Dependencies

- Requires investigation of ghostty's scrollback/screen content API
- May need `ghostty_surface_selection_*` functions or direct screen buffer access

---

## Implementation Order

1. **A: Polish** — Bell indicators, tab rename, preference pane (quick wins)
2. **B: Window mode** — Pane navigation, resize, break/merge/rotate/zoom
3. **D: Copy mode** — Scrollback navigation and selection (most complex)

## Testing Strategy

- Unit tests for all model changes (PaneLayout navigation, ratio adjustments, copy mode state)
- Manual testing for UI interactions (bell indicators, inline editing, window mode keybindings)
- Integration tests for preference persistence
