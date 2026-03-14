# UX Improvements Design

## Overview

Seven UX improvements organized into two parallel tracks by complexity. Track 1 contains quick wins that ship fast; Track 2 contains features requiring deeper integration work.

## Track 1: Quick Wins

### 1. Tab Switching Shortcuts

Three new shortcut groups wired through the existing `NotificationCenter` pattern in `MisttyApp.swift`, handled in `ContentView.swift`.

**Cmd-1 through Cmd-9 — Focus tab by index:**
- Register 9 keyboard shortcuts in `MisttyApp.commands`
- Handler sets `session.activeTab = session.tabs[index]` (bounds-checked, zero-indexed from Cmd-1)

**Cmd-] / Cmd-[ — Next/previous tab:**
- Compute current tab index in `session.tabs`
- Wrap around with modulo arithmetic

**Cmd-Shift-Up / Cmd-Shift-Down — Cycle sessions:**
- Compute current session index in `store.sessions`
- Wrap around with modulo
- Set `store.activeSession` to the target session

No model changes needed — purely keyboard wiring and `ContentView` notification handlers.

**Files modified:**
- `Mistty/App/MisttyApp.swift` — register shortcuts
- `Mistty/App/ContentView.swift` — handle notifications

### 2. Hide Current Session in Session Manager

When building the session manager item list in `SessionManagerViewModel.load()`, skip the session matching `store.activeSession`. The user is already in that session — showing it is noise.

One-line filter change in the existing logic where `.runningSession` items are appended.

**Files modified:**
- `Mistty/Views/SessionManager/SessionManagerViewModel.swift`

### 3. Frecency Sorting

The session manager currently shows items in fixed category order (running sessions, directories, SSH hosts). Frecency sorting promotes frequently and recently used items.

**Score storage:**
- New file `~/.config/mistty/frecency.json`
- Dictionary mapping item keys to `{frequency: Int, lastAccessed: Date}`
- Item keys use prefixed format: `session:<name>`, `dir:<path>`, `ssh:<alias>`

**FrecencyService:**
- New service class that reads/writes the frecency file
- `recordAccess(key: String)` — increments frequency, updates lastAccessed
- `score(key: String) -> Double` — returns weighted score

**Score calculation:**
- Formula: `score = frequency * recencyWeight`
- Recency weight by time since last access:
  - Last hour: 4x
  - Last day: 2x
  - Last week: 1x
  - Older: 0.5x

**Integration:**
- `SessionManagerViewModel.confirmSelection()` calls `FrecencyService.recordAccess()` when opening any item
- After building the combined items list in `load()`, sort by frecency score descending
- Items with no frecency data sort to the bottom, maintaining current category order as tiebreaker

**Files created:**
- `Mistty/Services/FrecencyService.swift`

**Files modified:**
- `Mistty/Views/SessionManager/SessionManagerViewModel.swift`

### 4. Join Pane to Tab (Window Mode)

The reverse of break-to-tab (B key). Pressing M in window mode opens a tab picker to move the active pane into another tab.

**Flow:**
1. User is in window mode, presses M
2. Overlay updates to show a numbered list of tabs in the current session (excluding current tab)
3. User presses 1, 2, 3, etc. to select the target tab
4. Active pane is removed from current tab's layout
5. Pane is inserted into the target tab's layout (appended as a horizontal split)
6. If source tab becomes empty, it's closed
7. Focus moves to the target tab

**Implementation:**
- Window mode gets a sub-state for join-pick mode (e.g. an enum: `.normal`, `.joinPick`)
- Window mode key monitor in `ContentView` handles M by entering join-pick state
- In join-pick state, number keys confirm selection, Escape returns to normal window mode
- Model operation mirrors `breakPaneToTab()` — remove pane from source layout, add to target layout
- `WindowModeHints` overlay updates to show the tab picker when in join-pick state

**Files modified:**
- `Mistty/App/ContentView.swift` — join mode handling in window mode monitor
- `Mistty/Views/Terminal/WindowModeHints.swift` — join-pick tab list UI

## Track 2: Complex Features

### 5. SSH Auto-Connect + Configurable Command

**Config format** in `~/.config/mistty/config.toml`:

```toml
[ssh]
default_command = "ssh"  # optional, defaults to "ssh"

[[ssh.host]]
hostname = "dev-box"
command = "et"

[[ssh.host]]
regex = "prod-.*"
command = "et"
```

- Each `[[ssh.host]]` entry has either `hostname` (exact string match) or `regex` (regex match), not both
- First match in config order wins
- `default_command` falls back to `"ssh"` if omitted

**Config parsing:**
- New `SSHConfig` struct in `MisttyConfig` with `defaultCommand` and `hosts` array
- Each host entry is an `SSHHostOverride` with optional `hostname`, optional `regex`, and `command`
- Validation: exactly one of `hostname` or `regex` must be present

**Session creation behavior:**

When opening an SSH host from the session manager:
1. Look up the host alias against configured `ssh.host` entries (first match wins)
2. Build the command string: `{resolved_command} {host_alias}`
3. Create a new session with `exec` set to that command
4. Store `sshCommand` on the session for pane inheritance

**Pane inheritance:**
- New panes in an SSH session inherit the session's `sshCommand` as their `exec`
- Holding Opt when splitting (Cmd-Opt-D / Cmd-Opt-Shift-D) creates a local pane instead
- `ContentView` checks for `.option` modifier flag on split notifications

**Model change:**
- `MisttySession` gets `sshCommand: String?`, set when created from an SSH host

**Preferences pane:**
- New SSH section in `SettingsView` to view/add/edit/remove host overrides
- Mirrors the popup preferences pattern

**Files modified:**
- `Mistty/Config/MisttyConfig.swift` — SSH config parsing
- `Mistty/Models/MisttySession.swift` — `sshCommand` property
- `Mistty/App/ContentView.swift` — Opt-modifier check on splits, SSH session creation
- `Mistty/Views/SessionManager/SessionManagerViewModel.swift` — build SSH command on selection
- `Mistty/Views/Settings/SettingsView.swift` — SSH overrides section

### 6. Smart Pane Navigation (Ctrl-H/J/K/L)

Ctrl-H/J/K/L navigates between MistTY panes. When the active pane runs neovim with smart-splits.nvim, keypresses pass through to neovim first — MistTY only navigates when neovim is at its split boundary.

**Protocol (industry standard, used by vim-tmux-navigator / smart-splits.nvim):**
1. MistTY intercepts Ctrl-H/J/K/L in `TerminalSurfaceView.keyDown()`
2. Check if the active pane is running neovim (via process title)
3. If NOT neovim: navigate panes directly using existing `PaneLayout` directional logic, don't send key to ghostty
4. If neovim: let the keypress through to ghostty (neovim receives it)
5. Neovim's smart-splits plugin attempts to move within its own splits
6. If neovim is at its boundary, smart-splits calls `mistty-cli pane focus --direction {left,right,up,down}`
7. MistTY's existing XPC handler moves focus to the adjacent pane

**Key interception:**
- In `TerminalSurfaceView.keyDown()`, before passing to ghostty, check for Ctrl+H/J/K/L
- Map to directions: H=left, J=down, K=up, L=right
- If pane title does not match neovim, post a notification for pane focus change and return (don't call ghostty)
- If pane title matches neovim, fall through to normal key handling

**Neovim detection:**
- Check the pane's associated tab title (set via `ghosttySetTitle` notification) for: `nvim`, `neovim`, `vim`
- Lightweight string check, no process table inspection needed

**Pane focus by direction:**
- Reuse existing directional navigation from window mode (`PaneLayout` operations)
- Extract into a shared method callable from both window mode and Ctrl-nav

**CLI callback (already exists):**
- `mistty-cli pane focus --direction {left,right,up,down}` is already implemented
- No changes needed on the CLI side

**Neovim user configuration (documented, not implemented by MistTY):**
```lua
require('smart-splits').setup({
  at_edge = function(direction)
    os.execute('mistty-cli pane focus --direction ' .. direction)
  end
})
```

**Files created:**
- `docs/integrations/neovim-smart-splits.md` — setup instructions for neovim users

**Files modified:**
- `Mistty/Views/Terminal/TerminalSurfaceView.swift` — Ctrl-H/J/K/L interception
- `Mistty/App/ContentView.swift` — shared directional focus handler

## File Change Summary

**New files:**
- `Mistty/Services/FrecencyService.swift`
- `docs/integrations/neovim-smart-splits.md`

**Modified files:**
- `Mistty/App/MisttyApp.swift` — tab/session switching shortcuts
- `Mistty/App/ContentView.swift` — shortcut handlers, join mode, Opt-split, Ctrl-nav
- `Mistty/Config/MisttyConfig.swift` — SSH config parsing
- `Mistty/Models/MisttySession.swift` — `sshCommand` property
- `Mistty/Views/SessionManager/SessionManagerViewModel.swift` — hide current session, frecency sort, SSH command resolution
- `Mistty/Views/Settings/SettingsView.swift` — SSH overrides section
- `Mistty/Views/Terminal/TerminalSurfaceView.swift` — Ctrl-H/J/K/L interception
- `Mistty/Views/Terminal/WindowModeHints.swift` — join-pick tab list UI
- `Mistty/Services/FrecencyService.swift` — frecency scoring and persistence

## Testing

- **Tab shortcuts:** Unit test for index bounds, wrap-around logic
- **Frecency:** Unit tests for score calculation, decay weights, recording access, JSON persistence
- **SSH config:** Unit tests for hostname exact match, regex match, first-match-wins, default fallback
- **Join pane:** Unit test in SessionStoreTests for pane move between tabs, source tab cleanup
- **Smart-nav:** Unit test for neovim title detection, direction mapping
