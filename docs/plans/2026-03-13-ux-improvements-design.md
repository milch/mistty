# UX Improvements Design

## Overview

Seven UX improvements organized into two parallel tracks by complexity. Track 1 contains quick wins that ship fast; Track 2 contains features requiring deeper integration work.

## Track 1: Quick Wins

### 1. Tab Switching Shortcuts

Three new shortcut groups wired through the existing `NotificationCenter` pattern in `MisttyApp.swift`, handled in `ContentView.swift`.

**Cmd-1 through Cmd-9 — Focus tab by index:**
- Register 9 keyboard shortcuts in `MisttyApp.commands`
- New notification names: `.misttyFocusTab1` through `.misttyFocusTab9`
- Handler guards on active session and bounds-checks: `guard let session = store.activeSession, index < session.tabs.count else { return }`, then sets `session.activeTab = session.tabs[index]`

**Cmd-] / Cmd-[ — Next/previous tab:**
- New notification names: `.misttyNextTab`, `.misttyPrevTab`
- Compute current tab index in `session.tabs`
- Wrap around with modulo arithmetic

**Cmd-Shift-Up / Cmd-Shift-Down — Cycle sessions (creation order):**
- New notification names: `.misttyNextSession`, `.misttyPrevSession`
- Compute current session index in `store.sessions` (ordered by creation time)
- Wrap around with modulo
- Set `store.activeSession` to the target session
- Note: session order is append-only (creation order); closing sessions shifts indices but order remains stable

No model changes needed — purely keyboard wiring and `ContentView` notification handlers.

**Files modified:**
- `Mistty/App/MisttyApp.swift` — register shortcuts, add notification names
- `Mistty/App/ContentView.swift` — handle notifications

### 2. Hide Current Session in Session Manager

When building the session manager item list in `SessionManagerViewModel.load()`, skip the session matching `store.activeSession`. The user is already in that session — showing it is noise.

One-line filter change in the existing logic where `.runningSession` items are appended.

**Files modified:**
- `Mistty/Views/SessionManager/SessionManagerViewModel.swift`

### 3. Frecency Sorting

The session manager currently shows items in fixed category order (running sessions, directories, SSH hosts). Frecency sorting promotes frequently and recently used items.

**Score storage:**
- New file `~/Library/Application Support/com.mistty/frecency.json` (macOS convention: mutable state in Application Support, not config dir)
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
- Window mode gets a sub-state enum on `MisttyTab`: `enum WindowModeState { case inactive, normal, joinPick }` (replaces the current `isWindowModeActive` bool)
- Window mode key monitor in `ContentView` handles M by entering `.joinPick` state
- In join-pick state, number keys confirm selection, Escape returns to `.normal`
- New method on `MisttyTab`: `addExistingPane(_ pane: MisttyPane, direction: SplitDirection)` — inserts an existing pane into the tab's layout tree (distinct from `splitActivePane` which creates a new pane)
- Model operation: remove pane from source tab's layout, call `targetTab.addExistingPane(pane, direction: .horizontal)` to insert into target
- `WindowModeHints` overlay updates to show the tab picker when in `.joinPick` state

**Files modified:**
- `Mistty/Models/MisttyTab.swift` — `WindowModeState` enum, `addExistingPane()` method
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
- `ContentView` handles the split notification and passes `sshCommand` to the pane creation path — `ContentView` has access to both `store.activeSession` and the Opt modifier flag, so it's the right place to wire this
- The pane's `command` property is set to the SSH command string before the surface is created

**Model change:**
- `MisttySession` gets `sshCommand: String?`, set when created from an SSH host

**Config persistence:**
- `MisttyConfig.save()` must be updated to serialize the `[ssh]` section (default_command and host overrides) alongside existing config fields

**Preferences pane:**
- New SSH section in `SettingsView` to view/add/edit/remove host overrides
- Mirrors the popup preferences pattern

**Files modified:**
- `Mistty/Config/MisttyConfig.swift` — SSH config parsing and `save()` serialization
- `Mistty/Models/MisttySession.swift` — `sshCommand` property
- `Mistty/App/ContentView.swift` — Opt-modifier check on splits, SSH command inheritance via pane's `command` property, SSH session creation
- `Mistty/Views/SessionManager/SessionManagerViewModel.swift` — build SSH command on selection
- `Mistty/Views/Settings/SettingsView.swift` — SSH overrides section

### 6. Smart Pane Navigation (Ctrl-H/J/K/L)

Ctrl-H/J/K/L navigates between MistTY panes. When the active pane runs neovim with smart-splits.nvim, keypresses pass through to neovim first — MistTY only navigates when neovim is at its split boundary.

**Protocol (industry standard, used by vim-tmux-navigator / smart-splits.nvim):**
1. MistTY intercepts Ctrl-H/J/K/L via a local event monitor in `ContentView` (consistent with how window mode and copy mode already intercept keys)
2. Check if the active pane is running neovim (via pane's `processTitle` property)
3. If NOT neovim: navigate panes directly using existing `PaneLayout` directional logic, consume the event
4. If neovim: let the keypress through (neovim receives it)
5. Neovim's smart-splits plugin attempts to move within its own splits
6. If neovim is at its boundary, smart-splits calls `mistty-cli pane focus --direction {left,right,up,down}`
7. MistTY's XPC handler resolves the direction and moves focus

**Key interception:**
- Use a local key event monitor in `ContentView` (not `TerminalSurfaceView.keyDown()`, which lacks access to tab/session context)
- Check for Ctrl+H/J/K/L events
- Map to directions: H=left, J=down, K=up, L=right
- If active pane's `processTitle` does not match neovim, handle navigation directly and return the event as consumed
- If active pane's `processTitle` matches neovim, return nil to let the event pass through

**Neovim detection:**
- New `processTitle: String?` property on `MisttyPane`, updated when `ghosttySetTitle` notifications arrive (ContentView already receives these and can route to the pane)
- Check for process names: `nvim`, `neovim`, `vim` as a substring of the process title
- This is more reliable than checking tab title, since tab title may be user-customized

**Pane focus by direction:**
- Reuse existing directional navigation from window mode (`PaneLayout` operations)
- Extract into a shared method callable from both window mode and Ctrl-nav

**CLI callback (new — does not exist yet):**
- Add `--direction {left,right,up,down}` option to `mistty-cli pane focus` (currently only supports `--id`)
- Add `focusPaneByDirection(direction:sessionId:reply:)` method to `MisttyServiceProtocol`
- Implement in `XPCService` using `PaneLayout` directional navigation on the active tab of the specified (or first) session

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
- `Mistty/App/ContentView.swift` — Ctrl-H/J/K/L local event monitor, shared directional focus handler
- `Mistty/Models/MisttyPane.swift` — `processTitle` property
- `MisttyShared/MisttyServiceProtocol.swift` — `focusPaneByDirection` method
- `Mistty/Services/XPCService.swift` — implement `focusPaneByDirection`
- `MisttyCLI/Commands/PaneCommand.swift` — `--direction` option on focus subcommand

## File Change Summary

**New files:**
- `Mistty/Services/FrecencyService.swift`
- `docs/integrations/neovim-smart-splits.md`

**Modified files:**
- `Mistty/App/MisttyApp.swift` — tab/session switching shortcuts, notification names
- `Mistty/App/ContentView.swift` — shortcut handlers, join mode, Opt-split, Ctrl-H/J/K/L event monitor
- `Mistty/Config/MisttyConfig.swift` — SSH config parsing and `save()` serialization
- `Mistty/Models/MisttySession.swift` — `sshCommand` property
- `Mistty/Models/MisttyTab.swift` — `WindowModeState` enum, `addExistingPane()` method
- `Mistty/Models/MisttyPane.swift` — `processTitle` property
- `Mistty/Views/SessionManager/SessionManagerViewModel.swift` — hide current session, frecency sort, SSH command resolution
- `Mistty/Views/Settings/SettingsView.swift` — SSH overrides section
- `Mistty/Views/Terminal/WindowModeHints.swift` — join-pick tab list UI
- `MisttyShared/MisttyServiceProtocol.swift` — `focusPaneByDirection` method
- `Mistty/Services/XPCService.swift` — implement `focusPaneByDirection`
- `MisttyCLI/Commands/PaneCommand.swift` — `--direction` option on focus subcommand

## Testing

- **Tab shortcuts:** Unit test for index bounds, wrap-around logic
- **Frecency:** Unit tests for score calculation, decay weights, recording access, JSON persistence
- **SSH config:** Unit tests for hostname exact match, regex match, first-match-wins, default fallback
- **Join pane:** Unit test in SessionStoreTests for pane move between tabs, source tab cleanup
- **Smart-nav:** Unit test for neovim title detection, direction mapping
