# Configurable keyboard shortcuts

**Status:** design
**Date:** 2026-04-28
**Scope:** PLAN.md → "Keyboard shortcut configuration".

Make Mistty's global / menu-bar keyboard shortcuts configurable from
`~/.config/mistty/config.toml`, rebind four actions to mirror Arc/Zen
conventions (one of which is genuinely new), and collapse today's three
NSEvent monitors into one config-driven router.

## Goals

- Every global shortcut today defined in `Mistty/App/MisttyApp.swift`'s
  `.commands { CommandGroup }` block becomes overridable via a `[shortcuts]`
  TOML table.
- A new `close_window` action is added (default `cmd+shift+w`) and the
  existing `close_tab` action moves to `cmd+ctrl+w`. The session-cycle and
  session-swap actions swap their arrow-key modifiers; bracket aliases keep
  their existing meaning.
- Shortcut config participates in the existing live-reload pipeline
  (`MisttyConfig.reload()` → `.misttyConfigDidReload`). Editing
  `config.toml` and saving — or `mistty-cli config reload` — re-binds
  chords without restart.

## Non-goals

- Settings UI. PLAN.md slots a *recorder* under the future preference-pane
  redesign; this work doesn't add a viewer or text-field editor either.
- In-mode keys: window-mode (`hjkl`, `r`, `b`, `m`, `1`–`5`, `z`) and
  copy-mode (`hjkl`, `wWeEbB`, `f/F/t/T`, `vV<C-v>`, `y`/`o`/`Y`,
  search) stay hardcoded. They're tmux/vim conventions and remapping
  them adds significant per-submode surface for little real-world
  demand. (The *global* `cmd+shift+y` that enters yank-hint mode is
  configurable as the `yank_hints` action; only the in-mode keys
  themselves are not.)
- Per-popup shortcuts. Already configured inline on each `[[popup]]`
  entry; unchanged.
- Chord sequences (tmux-prefix `ctrl+b → c` style). Single-chord only.
- Ghostty-owned chords. Bindings active inside the terminal surface
  (`cmd+c` copy, `cmd+v` paste, anything set via `[ghostty]` passthrough
  `keybind`) still win inside the surface — we can't introspect them.

## Behavior changes

| Action | Today | After |
|---|---|---|
| `close_pane` | `cmd+w` | `cmd+w` (unchanged) |
| `close_tab` | `cmd+shift+w` | **`cmd+ctrl+w`** |
| `close_window` | (no shortcut) | **`cmd+shift+w`** (new action) |
| `next_session` | `cmd+shift+up`/`cmd+shift+down`, `cmd+shift+]`/`cmd+shift+[` | **`cmd+opt+up`/`cmd+opt+down`**, `cmd+shift+]`/`cmd+shift+[` |
| `swap_session_*` | `cmd+opt+up`/`cmd+opt+down`, `cmd+opt+]`/`cmd+opt+[` | **`cmd+shift+up`/`cmd+shift+down`**, `cmd+opt+]`/`cmd+opt+[` |

Everything else (`cmd+t`, `cmd+w`, `cmd+x`, `cmd+j`, `cmd+d`, `cmd+s`,
`cmd+1..9`, `ctrl+1..9`, bracket-based tab cycling, etc.) keeps its
current default.

The arrow shortcuts adopt the new Arc/Zen-aligned mapping. The bracket
shortcuts keep their existing meaning, by request — preserves muscle
memory for current users. The trade-off: `cmd+shift+down` (swap
session) and `cmd+shift+]` (cycle session) share the `cmd+shift`
modifier but bind to different actions, and the same is true for
`cmd+opt+arrows` vs `cmd+opt+brackets`. Deliberate, called out in the
example config so it doesn't read like a bug.

`close_window` is genuinely new. Today the OS handles close-window via
the title bar's red traffic light only. The new action posts a
`misttyCloseWindow` notification handled at `WindowRootView` /
`WindowsStore` that calls `NSApp.keyWindow?.performClose(nil)` only when
the key window is one of our terminal windows (same guard as
`close_pane`).

## Design

### Schema

`config.toml` gains a `[shortcuts]` table. Layered semantics: every
action has a default chord baked in code; user entries override
per-action; missing entries keep the default.

```toml
[shortcuts]
# Single chord
new_tab          = "cmd+t"
new_tab_plain    = "cmd+opt+t"
close_pane       = "cmd+w"
close_tab        = "cmd+ctrl+w"
close_window     = "cmd+shift+w"
window_mode      = "cmd+x"
copy_mode        = "cmd+shift+c"
yank_hints       = "cmd+shift+y"
session_manager  = "cmd+j"
toggle_sidebar   = "cmd+s"
toggle_tab_bar   = "cmd+shift+b"
reload_config    = ""                 # "" disables a default
split_horizontal       = "cmd+d"
split_horizontal_plain = "cmd+opt+d"
split_vertical         = "cmd+shift+d"
split_vertical_plain   = "cmd+shift+opt+d"
reopen_closed_window   = "cmd+shift+t"
rename_tab     = "cmd+shift+r"
rename_session = "cmd+opt+r"

# Multi-binding (string-or-array)
next_tab          = ["cmd+]", "cmd+down"]
prev_tab          = ["cmd+[", "cmd+up"]
next_session      = ["cmd+opt+down", "cmd+shift+]"]
prev_session      = ["cmd+opt+up",   "cmd+shift+["]
swap_session_down = ["cmd+shift+down", "cmd+opt+]"]
swap_session_up   = ["cmd+shift+up",   "cmd+opt+["]

# Indexed actions: a single base modifier, applies to 1..9
focus_tab_modifier     = "cmd"        # cmd+1..cmd+9
focus_session_modifier = "ctrl"       # ctrl+1..ctrl+9
```

`focus_tab_*` and `focus_session_*` collapse 18 actions into two entries
because the realistic configuration space is "what modifier does the
1..9 row use," not "rebind cmd+1 individually." Loses fine-grained
per-index remapping; acceptable.

### Action registry

```swift
enum ShortcutAction: String, CaseIterable {
  case newTab               = "new_tab"
  case newTabPlain          = "new_tab_plain"
  case closePane            = "close_pane"
  case closeTab             = "close_tab"
  case closeWindow          = "close_window"
  case windowMode           = "window_mode"
  case copyMode             = "copy_mode"
  case yankHints            = "yank_hints"
  case sessionManager       = "session_manager"
  case toggleSidebar        = "toggle_sidebar"
  case toggleTabBar         = "toggle_tab_bar"
  case reloadConfig         = "reload_config"
  case splitHorizontal      = "split_horizontal"
  case splitHorizontalPlain = "split_horizontal_plain"
  case splitVertical        = "split_vertical"
  case splitVerticalPlain   = "split_vertical_plain"
  case reopenClosedWindow   = "reopen_closed_window"
  case renameTab            = "rename_tab"
  case renameSession        = "rename_session"
  case nextTab              = "next_tab"
  case prevTab              = "prev_tab"
  case nextSession          = "next_session"
  case prevSession          = "prev_session"
  case swapSessionDown      = "swap_session_down"
  case swapSessionUp        = "swap_session_up"
  // Indexed actions handled out-of-band via *_modifier keys.
}

extension ShortcutAction {
  static let defaults: [ShortcutAction: [Chord]] = [
    .newTab:               [Chord("cmd+t")!],
    .newTabPlain:          [Chord("cmd+opt+t")!],
    .closePane:            [Chord("cmd+w")!],
    .closeTab:             [Chord("cmd+ctrl+w")!],
    .closeWindow:          [Chord("cmd+shift+w")!],
    .windowMode:           [Chord("cmd+x")!],
    .copyMode:             [Chord("cmd+shift+c")!],
    .yankHints:            [Chord("cmd+shift+y")!],
    .sessionManager:       [Chord("cmd+j")!],
    .toggleSidebar:        [Chord("cmd+s")!],
    .toggleTabBar:         [Chord("cmd+shift+b")!],
    .reloadConfig:         [],
    .splitHorizontal:      [Chord("cmd+d")!],
    .splitHorizontalPlain: [Chord("cmd+opt+d")!],
    .splitVertical:        [Chord("cmd+shift+d")!],
    .splitVerticalPlain:   [Chord("cmd+shift+opt+d")!],
    .reopenClosedWindow:   [Chord("cmd+shift+t")!],
    .renameTab:            [Chord("cmd+shift+r")!],
    .renameSession:        [Chord("cmd+opt+r")!],
    .nextTab:              [Chord("cmd+]")!, Chord("cmd+down")!],
    .prevTab:              [Chord("cmd+[")!, Chord("cmd+up")!],
    .nextSession:          [Chord("cmd+opt+down")!, Chord("cmd+shift+]")!],
    .prevSession:          [Chord("cmd+opt+up")!,   Chord("cmd+shift+[")!],
    .swapSessionDown:      [Chord("cmd+shift+down")!, Chord("cmd+opt+]")!],
    .swapSessionUp:        [Chord("cmd+shift+up")!,   Chord("cmd+opt+[")!],
  ]
}
```

A unit test asserts every `ShortcutAction` case has an entry in
`defaults`, catching the case where an enum case is added without a
default.

Indexed actions store a `IndexedShortcut` struct on the registry
holding the parsed modifiers for tabs and sessions, with defaults
`cmd` and `ctrl` respectively.

### `Chord` type

```swift
struct Chord: Hashable {
  enum Key: Hashable {
    case character(Character)        // "a", "1", "]"
    case special(Special)            // arrows, brackets, function keys
  }
  enum Special: String { case up, down, left, right,
                              escape, `return`, tab, space,
                              backspace, home, end,
                              pageUp = "pageup", pageDown = "pagedown",
                              f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12 }

  let key: Key
  let modifiers: NSEvent.ModifierFlags  // intersection of [.command, .shift, .option, .control]

  init?(_ raw: String)                  // string parser, returns nil on failure
  func swiftUI() -> (KeyEquivalent, EventModifiers)
  func matches(_ event: NSEvent) -> Bool
}
```

One type used by both the SwiftUI menu (`swiftUI()`) and the AppKit
local monitor (`matches(_:)`). `Hashable` so it can act as a key in the
reverse index for conflict detection.

The popup-shortcut parser at `MisttyApp.swift:334-354` is the existing
precedent for this format; it'll be deleted and replaced with calls
through `Chord(_:)`. Popup definitions in `PopupDefinition` switch from
storing a raw `String?` to storing a parsed `Chord?`.

### Chord grammar

- Lowercased, separator `+` or `-`, modifiers first, key last.
- Modifiers: `cmd`/`command`, `shift`, `opt`/`option`/`alt`,
  `ctrl`/`control`. Order doesn't matter; duplicates de-duped.
- Key tokens: any single Unicode character (`a`, `]`, `1`, `/`) OR a
  special-key word from `Chord.Special.allCases`.
- Matching is layout-independent for special keys (matched via
  `event.keyCode`) and `charactersIgnoringModifiers`-based for regular
  characters. Bracket keys go through the special-key path because
  shift-bracket on a US layout produces `{`/`}` from
  `charactersIgnoringModifiers`, breaking a string-equality match.
- `""` (empty string) — explicitly disables a default. Resolved to
  `[]` for that action.
- Anything else — parse failure, captured in
  `MisttyConfig.lastParseError` with the offending action name + chord
  string. Reload aborts (existing semantics).

### Resolution & validation

`ShortcutRegistry` is built once per parsed `MisttyConfig`. Steps:

1. Start from `ShortcutAction.defaults`.
2. For each entry in the user's `[shortcuts]` table:
    - If the key matches a known `ShortcutAction.rawValue`, parse the
      value (string or array). Empty string ⇒ `[]`. Replace that
      action's chord list.
    - If the key is `focus_tab_modifier` / `focus_session_modifier`,
      parse the modifiers-only chord (no key allowed) and store it on
      `IndexedShortcut`.
    - Unknown key ⇒ parse error with key name.
3. Build a reverse index `[Chord: [ShortcutAction]]` across all
   resolved chords.
4. Any chord with >1 action ⇒ collect into
   `ShortcutConfigError.conflict([(Chord, [ShortcutAction])])` and
   throw. The error lists *every* collision in one banner so users fix
   them in one pass.
5. Indexed-action modifier check: if `focus_tab_modifier == focus_session_modifier`
   ⇒ throw `.indexedModifierClash`.
6. Allowed: same chord listed twice for the same action — silently
   deduped.

Errors flow through `MisttyConfig.reload()`'s existing path:
`lastParseError` set, banner in Settings, `mistty-cli config reload`
exits non-zero, `MisttyConfig.current` stays on the last good snapshot.

### Architecture

**`ShortcutRegistry`** (new, `Mistty/Config/ShortcutRegistry.swift`)
holds `[ShortcutAction: [Chord]]` plus the indexed-action modifiers,
exposes `lookup(event: NSEvent) -> ShortcutAction?` and
`chords(for: ShortcutAction) -> [Chord]`. Lookup matches against the
reverse index plus the indexed-action modifiers (digit keys 1–9 with
the configured modifier).

**`ShortcutMonitor`** (new, `Mistty/Services/ShortcutMonitor.swift`)
owns a single `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`.
On every key-down:

1. Window-key guard: only act when the key window is one of our tracked
   terminal windows (preserves today's "let Settings handle its own
   chords" behavior — see the existing closeMonitor at
   `ContentView.swift:1294-1320`).
2. `registry.lookup(event:)` → `ShortcutAction?`. No match ⇒ return the
   event unchanged.
3. Apply per-action *fire policy* (see below). Policy denies ⇒ return
   the event unchanged. Allows ⇒ post the action's notification + return
   `nil` to consume.

The monitor is installed at `ContentView.onAppear` and torn down in
`onDisappear`, mirroring today's `closeMonitor`/`windowModeShortcutMonitor`/
`altShortcutMonitor` lifecycle. It listens on
`.misttyConfigDidReload` and rebuilds its snapshot of the registry so
edits take effect live.

**Per-action fire policy** is a `ShortcutAction.policy: FirePolicy`
property. Encodes the guards that today live as inline conditions in
the three monitors:

```swift
struct FirePolicy {
  // Every shortcut today gates on this — added as a field anyway so
  // future actions (e.g. global hotkeys) can opt out cleanly.
  var requiresTerminalWindowKey: Bool = true
  // Cmd+X must fall through to system Cut when a text field has focus.
  var passThroughWhenTextResponder: Bool = false
  // Disable while window-mode / copy-mode / session-manager owns input.
  var disabledInModalModes: Bool = false
}

extension ShortcutAction {
  var policy: FirePolicy {
    switch self {
    case .closePane, .closeTab, .closeWindow:
      return FirePolicy(requiresTerminalWindowKey: true)
    case .windowMode:
      return FirePolicy(passThroughWhenTextResponder: true)
    case .nextTab, .prevTab, .nextSession, .prevSession,
         .swapSessionDown, .swapSessionUp:
      return FirePolicy(disabledInModalModes: true)
    default:
      return FirePolicy()
    }
  }
}
```

`disabledInModalModes` covers the existing
"`activeTab?.isWindowModeActive != true && activeTab?.isCopyModeActive != true && !showingSessionManager`"
guard at `ContentView.swift:1232-1239`. The monitor checks these on
the live `WindowsStore` / `state` it captures.

**Menu binding** in `MisttyApp.swift`. Each Button's
`.keyboardShortcut(...)` reads
`registry.chords(for: .someAction).first?.swiftUI()` and applies it (or
omits the modifier when there's no binding). The menu's *displayed*
chord is the primary alias only — matches today's behavior. The menu
already rebuilds via `@State config` + `.misttyConfigDidReload`, so a
config edit refreshes the menu hint live.

The Button's action closure still posts the action's notification —
unchanged. SwiftUI menu shortcuts also fire from menu-bar mouse clicks,
so the action closure has to keep working independently of the
keyboard path.

**Double-fire avoidance.** `ShortcutMonitor`'s local monitor runs
*before* SwiftUI's menu-shortcut routing, so when it consumes an event
SwiftUI never sees it. When the user clicks the menu item with a
mouse, only the SwiftUI path fires (no NSEvent intercept). The two
paths converge at the action closure / notification.

### Settings, save, IPC

- `MisttyConfig.save()` emits `[shortcuts]` only for actions whose
  resolved chord list differs from the default. Round-trip stays clean
  for unmodified configs.
- `mistty-cli config reload` — unchanged; benefits automatically.
- The annotated `docs/config-example.toml` gains a fully populated
  `[shortcuts]` block listing every action with its default value
  (commented), plus the bracket/arrow-modifier inconsistency callout.

## Migration

No on-disk migration. `[shortcuts]` doesn't exist in any user's config
today, so the layered defaults take over and every existing chord
keeps working — except the four actions PLAN.md is intentionally
swapping. Release notes for v0.10:

> **Breaking:** `cmd+shift+w` now closes the window (was: close tab).
> Close tab moved to `cmd+ctrl+w`. Restore the old binding by adding to
> `~/.config/mistty/config.toml`:
>
> ```toml
> [shortcuts]
> close_tab    = "cmd+shift+w"
> close_window = ""    # disable
> ```
>
> Session cycling moved from `cmd+shift+arrows` to `cmd+opt+arrows`;
> session swapping is now `cmd+shift+arrows`. Bracket-based aliases
> (`cmd+shift+brackets`, `cmd+opt+brackets`) keep their previous
> meaning.

## Test plan

Unit tests in `MisttyTests/`:

- `ChordParserTests` — round-trip every default chord, rejection cases
  (unknown modifier, multiple keys, empty parts), `cmd-x` / `cmd+x`
  separator parity.
- `ShortcutRegistryTests` — defaults coverage (every action has at least
  one default OR is the explicitly-empty `reloadConfig`), user override
  replaces defaults, empty-string disables, unknown action key throws,
  conflict detection (build a config that double-binds, expect collected
  error listing both actions), indexed-modifier clash throws, indexed
  modifier defaults are `cmd` / `ctrl`.
- `ShortcutMonitorTests` — synthesize `NSEvent` keyDown events through
  the monitor's lookup-and-fire path; assert each policy gate
  (terminal-window-key, text-responder pass-through, modal-mode
  disable). Doesn't run a real event loop; calls the monitor's handler
  closure directly with hand-built events.
- `MisttyConfigSaveTests` — save+parse round-trip, default-equal entries
  omitted, custom entries preserved including arrays.

Manual verification:

- `cmd+shift+w` closes the window. `cmd+ctrl+w` closes the tab.
  `cmd+w` still closes the pane.
- `cmd+opt+up`/`cmd+opt+down` cycle sessions; `cmd+shift+up`/`cmd+shift+down`
  swap. Bracket aliases continue to do their previous things.
- Edit `[shortcuts] new_tab = "cmd+shift+t"` then save Settings — menu
  hint updates, `cmd+shift+t` opens a new tab, `cmd+t` falls through to
  the terminal.
- Bind two actions to the same chord — Settings shows the conflict
  banner; `MisttyConfig.current` stays on the last good snapshot.
- `mistty-cli config reload` after a bad edit — exits non-zero with the
  conflict / parse error message.
- Cmd+X inside a sidebar rename text field still cuts text (policy
  pass-through).
- Cmd+W inside the Settings window closes Settings (policy
  terminal-window-key check).

## File touches

New:

- `Mistty/Config/Chord.swift`
- `Mistty/Config/ShortcutAction.swift`
- `Mistty/Config/ShortcutRegistry.swift`
- `Mistty/Services/ShortcutMonitor.swift`
- `MisttyTests/ChordParserTests.swift`
- `MisttyTests/ShortcutRegistryTests.swift`
- `MisttyTests/ShortcutMonitorTests.swift`

Modified:

- `Mistty/Config/MisttyConfig.swift` — add `shortcuts: ShortcutsConfig`,
  parse `[shortcuts]` table, save round-trip.
- `Mistty/App/MisttyApp.swift` — replace inline `.keyboardShortcut(...)`
  literals with `registry.chords(for:).first?.swiftUI()` reads. Add a
  `Close Window` menu item. Delete the popup-shortcut parser
  (replaced by `Chord(_:)`). Add a single new notification name,
  `.misttyCloseWindow`. The "swap session" actions
  (`swap_session_up`/`swap_session_down`) reuse the existing
  `.misttyMoveSessionUp`/`.misttyMoveSessionDown` notifications —
  semantically equivalent (moving a session up by one position *is*
  swapping with its prior neighbour), and reusing the wiring keeps the
  diff small.
- `Mistty/App/ContentView.swift` — delete `altShortcutMonitor`,
  `closeMonitor`, `windowModeShortcutMonitor` (and their install /
  remove helpers). Install `ShortcutMonitor` from `onAppear`. The
  notification handlers stay; they're driven by the monitor now.
- `Mistty/Models/PopupDefinition.swift` — change `shortcut: String?` to
  `shortcut: Chord?`. Parser failures during `[shortcuts]` resolution
  surface through the same error path.
- `Mistty/App/WindowRootView.swift` (or `WindowsStore`) — handle
  `misttyCloseWindow` by performing close on the active terminal NSWindow.
- `docs/config-example.toml` — add the `[shortcuts]` block.

## Risks

- **Live menu rebuild on reload.** SwiftUI's
  `CommandGroup`/`.keyboardShortcut(...)` is generally responsive to
  `@State` changes, but menu shortcut hints can occasionally lag a
  rebuild on macOS. If we hit this, the chord still works (the monitor
  is the actual binding) — only the *displayed* hint goes stale. Worst
  case acceptable.
- **`Chord` `Hashable` for arrow keys.** The `Special` enum gives us a
  layout-independent identity. Confirmed by reading the existing
  `event.keyCode == 126` (up arrow) checks at `ContentView.swift:1242`.
- **Popup definitions changing shape.** `PopupDefinition.shortcut`
  becoming a parsed `Chord?` instead of a raw string is a small ripple
  through `[[popup]]` parsing, save, and Settings binding. Keep the
  Settings text field as a `String` view-state, parse on save (matches
  how validation already works for SSH command overrides).
