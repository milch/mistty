# Copy-mode multi-screen yank & config reload

**Status:** design
**Date:** 2026-04-25
**Scope:** Two independent items from PLAN.md → Misc & Bugs:
1. Yank in copy mode produces wrong text once the selection spans more than the visible viewport.
2. No way to reload `~/.config/mistty/config.toml` short of restarting the app.

## Item 1 — Multi-screen copy-mode yank

### Symptom

In copy mode, with any visual sub-mode (`v`, `V`, `Ctrl-v`), once the selection
is dragged past the viewport into scrollback, yank produces only one (or a few)
lines of text instead of the highlighted region. The visual highlight itself
stays correct because it normalizes (row, col) endpoints; only the byte capture
is wrong.

### Root cause

`vendor/ghostty/src/apprt/embedded.zig:1346-1347`, in the C-API `Selection.pin`
helper:

```zig
const clamped_x = @min(self.x, screen.pages.cols -| 1);
const clamped_y = @min(self.y, screen.pages.rows -| 1);
```

`screen.pages.rows` is the **viewport height** (e.g. 24), not `total_rows` which
also covers scrollback. The clamp is applied unconditionally, regardless of the
point's tag (`active` / `viewport` / `screen` / `history`). When Mistty passes a
`GHOSTTY_POINT_SCREEN` selection whose `y` extends into scrollback, both
endpoints get clamped to `viewport_height - 1`, collapsing the selection to a
sliver near the top of the visible viewport.

This makes the embedded `SCREEN` and `HISTORY` tags effectively unusable for
any cross-viewport read. The same call site is what `read_text` runs through,
which is why the visible highlight (drawn entirely in Mistty) is correct but
the yanked text isn't.

A secondary bug exists in Mistty's own yank: the `.visual` (character-wise)
case at `Mistty/App/ContentView.swift:1466-1475` does not normalize start and
end via min/max. When the cursor is positioned lexicographically before the
anchor (selecting upward, even within a single screen), `top_left.y >
bottom_right.y` and ghostty rejects/inverts the selection. `.visualLine` and
`.visualBlock` already normalize.

### Fix

**Layer 1 — libghostty patch (`patches/ghostty/0004-screen-tag-pin-clamp.patch`).**
Make the y-clamp tag-aware:

```zig
const clamped_x = @min(self.x, screen.pages.cols -| 1);
const max_y: usize = switch (self.tag) {
    .active, .viewport => screen.pages.rows,
    .screen, .history => screen.pages.total_rows,
};
const clamped_y = @min(self.y, max_y -| 1);
```

`x` clamping stays as-is (column count is the same in every coordinate
system). `total_rows` is the field PageList already exposes for scrollbar
total, so this adds no new state.

The patch follows the existing `patches/ghostty/000N-*.patch` convention and
gets applied via `just patch-ghostty` before `just build-libghostty`. No
upstream PR for v1 — local patch only, matching the precedent of the three
existing patches.

**Layer 2 — Mistty `.visual` normalization.**
In `yankSelection()` at `ContentView.swift:1466-1475`, swap to a lexicographic
min/max so `top_left` is always the earlier point:

```swift
case .visual:
  let a = (anchor.row + offset, anchor.col)
  let c = (state.cursorRow + offset, state.cursorCol)
  let (top, bottom) = a < c ? (a, c) : (c, a)
  textToCopy = readGhosttyText(
    surface: surface,
    startRow: top.0, startCol: top.1,
    endRow: bottom.0, endCol: bottom.1,
    rectangle: false,
    pointTag: tag
  )
```

This is independent of the libghostty patch — both bugs are real, both need
fixing.

### Tests

- Add a regression test in `MisttyTests/Models/CopyModeIntegrationTests.swift`
  that drives the keystroke sequence `v` + `100k` + `y` against a mocked line
  reader spanning >2 viewport heights, and asserts that the resolved (top,
  bottom) coordinates passed to `readGhosttyText` are normalized and span the
  full requested range. The actual `read_text` call needs a live surface and is
  exercised by manual verification.
- A unit test for the `.visual` normalization that drives `v` + `5k` + `2h` (so
  cursor ends up before anchor in lexicographic order) and asserts top-left <
  bottom-right.

### Manual verification

`cat <(yes line | head -n 200)`, enter copy mode, `V`, scroll back with
`Ctrl-u` until the cursor is near the top of the dump, `y`, paste — should
yield ~200 lines, not one.

## Item 2 — Config reload

### Goal

Re-read `~/.config/mistty/config.toml` and apply changes without a restart.
Triggers: a menu item, a CLI command, and an implicit reload after Settings
saves the file. Most user-visible config takes effect immediately. The handful
of keys that genuinely need restart (initial-command for new surfaces,
`zoxide_path` after probe) are out of scope and undocumented for v1 — falling
out naturally from the architecture rather than being explicitly diff-warned.

### Non-goals (v1)

- Filesystem watcher (auto-reload on disk change).
- Per-key "needs restart" diff/warning UI.
- Auto-reloading the per-surface initial command — surfaces are spawned at
  creation, retroactive replacement isn't a config-reload concern.

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Triggers                                                        │
│   ├── View menu → "Reload Config" (no default shortcut)          │
│   ├── mistty-cli config reload                                   │
│   └── SettingsView.save() → calls reload after writing the file  │
│                                                                  │
│  MisttyConfig                                                    │
│   ├── static var current: MisttyConfig            (was: let)     │
│   ├── static func reload() throws -> MisttyConfig                │
│   │     re-parses configURL, swaps current, posts notification,  │
│   │     leaves current unchanged on parse error                  │
│   └── Notification.Name.misttyConfigDidReload                    │
│                                                                  │
│  Reactive consumers (listen for misttyConfigDidReload)           │
│   ├── GhosttyAppManager.reloadConfig()                           │
│   │     builds fresh ghostty_config_t from MisttyConfig.current  │
│   │     + ~/.config/mistty/ghostty.conf, calls                   │
│   │     ghostty_app_update_config(app, newCfg). Old cfg is       │
│   │     stashed in `retiredConfigs` and freed at app shutdown to │
│   │     avoid races against in-flight surface messages.          │
│   ├── MisttyApp (root view)                                      │
│   │     @State var config refreshes from current,                │
│   │     re-applies titleBarStyle to existing NSWindows           │
│   ├── TerminalSurfaceView                                        │
│   │     re-fetches scrollMultiplier, ui                          │
│   ├── ZoxideService                                              │
│   │     re-resolves zoxidePath if the override changed           │
│   └── SettingsView                                               │
│         if open, refreshes its @State from current so external   │
│         edits aren't masked by stale form values                 │
└──────────────────────────────────────────────────────────────────┘
```

### Data flow per trigger

**Menu / CLI:**

1. Trigger calls `MisttyConfig.reload()`.
2. `reload()` parses the file:
   - Success: swap `current`, post `misttyConfigDidReload`. Return new value.
   - Failure: throw. `current` unchanged.
3. The notification listener in `GhosttyAppManager` rebuilds the
   `ghostty_config_t` and calls `ghostty_app_update_config`. Ghostty propagates
   to all surfaces (font, scrollback, palette, padding, theme, etc. update
   live).
4. The notification listener on `MisttyApp`'s root view refreshes its `@State
   config` so SwiftUI re-renders pane borders, tab bar mode, title bar style,
   popup menu items.
5. CLI / menu paths surface parse errors via the existing
   `describeTOMLParseError` + NSAlert flow used at launch
   (`GhosttyApp.swift:231-257`).

**Settings save:**

1. `SettingsView.save()` writes the TOML, then calls `MisttyConfig.reload()`.
2. On parse error, the form shows an inline error (the existing alert path
   would be redundant since the user is looking at the form they just edited).
3. On success, the same notification flow as menu/CLI runs.

### libghostty live update

`vendor/ghostty/macos/Sources/Ghostty/Ghostty.App.swift:138-157` shows ghostty's
own AppKit reference impl: `ghostty_app_update_config(app, newCfg)` triggers
`App.updateConfig` (`src/App.zig:137`), which dispatches `change_config`
messages to every surface. That covers font, scrollback lines, padding,
palette, theme, cursor style, and any other ghostty-side knob — all live, no
surface recreation.

`GhosttyApp.swift:103-116` already calls `ghostty_app_update_config` for soft
reloads triggered by ghostty's color-scheme handling, so the lifetime model
(stash one config in `sharedGhosttyConfig`, free at deinit) extends naturally
to "stash multiple, free all at app shutdown".

### Reload scope (informative — not enforced by code)

| Key path                                | Live? | Reason                                    |
|-----------------------------------------|-------|-------------------------------------------|
| `font_size`, `font_family`              | ✅    | `ghostty_app_update_config` propagates    |
| `scrollback_lines`                      | ✅    | Same                                      |
| `cursor_style`                          | ✅    | Same                                      |
| `[ghostty]` passthrough keys            | ✅    | Same                                      |
| `[ui].content_padding_*`                | ✅    | Same                                      |
| `theme`, palette                        | ✅    | Same                                      |
| `[ui].pane_border_color/_width`         | ✅    | SwiftUI re-renders                        |
| `[ui].tab_bar_mode`, `title_bar_style`  | ✅    | SwiftUI + AppKit window restyle           |
| `[[popup]]`                             | ✅    | Menu rebuilds; in-flight popups unchanged |
| `[ssh]`                                 | ✅    | Read per-use                              |
| `[copy_mode.hints]`                     | ✅    | Read per-use                              |
| `scroll_multiplier`                     | ✅    | TerminalSurfaceView listens               |
| `debug_logging`                         | ✅    | Listener re-configures DebugLog           |
| `zoxide_path`                           | ⏳    | ZoxideService caches probe; restart       |
| Per-surface initial command             | ⏳    | Set at spawn time; not a reload concern   |
| `[[restore.command]]`                   | ✅    | Read at quit/launch only                  |

### Tests

- `MisttyConfigTests.testReload_swapsCurrentOnSuccess` — write a temp file,
  set `MisttyConfig.current` to a known value, call `reload(from: tempURL)`,
  assert `current` reflects the new file and the notification was posted.
- `MisttyConfigTests.testReload_keepsCurrentOnParseError` — write malformed
  TOML, call `reload`, assert it throws and `current` is unchanged.
- `MisttyConfigTests.testReload_postsNotificationOnce` — count posts, assert
  exactly one per successful reload.
- Manual verification: edit `pane_border_color` → reload → border updates.
  Same for `tab_bar_mode`, `font_size`, popup definitions.

## Risks

- **libghostty patch maintenance.** Mistty already maintains 3 patches; a 4th
  is incremental. No upstream PR in v1, so we own the rebase if ghostty's
  upstream `pin()` shape changes.
- **`ghostty_config_t` lifetime.** Freeing the previous config synchronously
  after `update_config` may race against in-flight surface message processing.
  Mitigation: stash retired configs in a list; free all at `GhosttyAppManager`
  deinit. Memory cost: a few KB per reload, negligible for an interactive app.
- **Listener fan-out.** Adding a new "I care about config reload" listener
  becomes a discovered-as-needed exercise. v1 ships the listeners we already
  know we need (ghostty, root view, terminal surface, zoxide); future
  additions follow the same pattern.

## Out of scope (deferred)

- File watcher on `~/.config/mistty/config.toml` for auto-reload.
- A "needs restart for X" toast or dialog.
- Reloading the initial command for already-spawned surfaces.
- Upstreaming the libghostty `pin()` patch.
