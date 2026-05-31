# OSC 9;4 progress bars

Date: 2026-05-31
Status: Design

## Problem

A program running in a pane can report task progress via the ConEmu
**OSC 9;4** sequence — `ESC ] 9 ; 4 ; state [ ; progress ] ST` — to drive a
taskbar-style progress indicator. Long jobs (builds, downloads, `apt`,
`npm`, `cargo`, `gh run watch`, …) increasingly emit it. Mistty currently
drops it.

libghostty already parses OSC 9;4 and surfaces it as a
`GHOSTTY_ACTION_PROGRESS_REPORT` action; Mistty just never handles it.

This feature renders that progress as a determinate bar on the tab (and a
mirror in the sidebar row), so the user can glance at a background tab and
see how far along its job is.

## Background — what libghostty gives us

From `vendor/ghostty/include/ghostty.h`:

```c
typedef enum {
  GHOSTTY_PROGRESS_STATE_REMOVE,
  GHOSTTY_PROGRESS_STATE_SET,
  GHOSTTY_PROGRESS_STATE_ERROR,
  GHOSTTY_PROGRESS_STATE_INDETERMINATE,
  GHOSTTY_PROGRESS_STATE_PAUSE,
} ghostty_action_progress_report_state_e;

typedef struct {
  ghostty_action_progress_report_state_e state;
  int8_t progress;   // -1 if no progress reported, otherwise 0–100
} ghostty_action_progress_report_s;
```

- The action is **surface-targeted**, so it maps back to a `MisttyPane`
  via the established `ghostty_surface_userdata` → `TerminalSurfaceView` →
  `pane` chain.
- libghostty clamps progress to 0–100 upstream; `-1` means "no percent".
- No vendored-ghostty changes are needed.

## Non-goals

- **Dock-icon progress.** A download-style bar on the Dock icon needs a
  custom `NSDockTile` content view + Core Graphics drawing and an app-wide
  aggregation rule. Deferred.
- **Window-title percent.** Not conventional for a terminal.
- **Persistence / history.** Progress is ephemeral runtime state, not
  snapshotted (same as `hasBell`).
- **Auto-timeout.** A program that reaches 100% and never sends `REMOVE`
  leaves a full bar; clearing is the program's contract (`REMOVE`). Mistty
  adds clear-on-pane-close but no speculative timeout.

## Design

### State model

A new value type is the single source of truth for how a bar renders:

```swift
enum PaneProgress: Equatable {
  case none            // no bar
  case running(Int)    // 0–100, determinate fill
  case indeterminate   // animated sweep (percent unknown)
  case paused(Int?)    // amber; optional fill
  case error(Int?)     // red; optional fill
}
```

To keep the mapper testable without importing `GhosttyKit` into the test
target, the C enum is decoded into a small Swift mirror at the callback
boundary:

```swift
enum ProgressState: Int {       // raw values match the ghostty enum order
  case remove = 0, set, error, indeterminate, pause
}
```

A **pure mapper** converts `(ProgressState, percent)` into `PaneProgress`.
It is a free function (file scope, unit-tested) so it never needs the
surface or the app running:

```swift
func paneProgress(state: ProgressState, percent: Int) -> PaneProgress
```

Mapping (`percent` is the raw `int8` value, `-1` when absent):

| ghostty state | percent | → `PaneProgress` |
| --- | --- | --- |
| `REMOVE` | (any) | `.none` |
| `SET` | 0–100 | `.running(clamped)` |
| `SET` | -1 | `.indeterminate` |
| `INDETERMINATE` | (any) | `.indeterminate` |
| `PAUSE` | 0–100 / -1 | `.paused(clamped?)` |
| `ERROR` | 0–100 / -1 | `.error(clamped?)` |

Clamping: values <0 (other than the -1 sentinel) → treat as absent; >100 →
100. libghostty already clamps, so this is defensive.

### Per-pane state

```swift
// MisttyPane (@Observable @MainActor)
var progress: PaneProgress = .none
```

Ephemeral, like `processTitle`. Lives on the **pane** (the emitter). Not
included in any `Snapshot` DTO.

### Data flow (mirrors the OSC-notifications feature)

1. A program emits `ESC]9;4;1;45 ST`.
2. libghostty parses it and fires `GHOSTTY_ACTION_PROGRESS_REPORT`
   (surface-targeted) with `{state, progress}`.
3. New `case GHOSTTY_ACTION_PROGRESS_REPORT` in
   `GhosttyApp.swift`'s `actionCallback`:
   - Read `action.action.progress_report.state` and `.progress`
     synchronously, decoding the `GhosttyKit` enum into the Swift
     `ProgressState` mirror and the `int8` into an `Int`.
   - Resolve the surface userdata → `view.pane?.id`.
   - `DispatchQueue.main.async` → post `.ghosttyProgressReport`
     (userInfo: `paneID`, `state` as the Swift mirror's raw value, `progress`).
4. **Consumer:** a single observer installed in `WindowsStore.init`
   (which already hosts the global `didBecomeKeyNotification` observer)
   resolves the pane via `pane(byId:)` and writes
   `pane.progress = paneProgress(state:percent:)`.

   *Why here, not a new singleton:* the OSC-notifications feature used a
   dedicated `NotificationService` because it owned a
   `UNUserNotificationCenter` delegate. A progress report has **no
   app-level side effect** — it is a pure model write — so a parallel
   service would be heavier than warranted. One observer in the existing
   global model owner, plus the pure mapper for the logic, keeps it lean
   and testable. Consuming once (rather than in every window's
   `ContentView`) avoids N redundant writes.

### Aggregation (multi-pane tab → one bar)

A tab can hold several split panes, each reporting independently. The tab
exposes a computed property (so `@Observable` tracks the child panes'
`progress`):

```swift
// MisttyTab
var aggregateProgress: PaneProgress { … }
```

Over the panes that are actively reporting (i.e. not `.none`):

1. any `.error` → `.error` (carry the least-complete error percent if any
   has one, else `nil`)
2. else any `.indeterminate` → `.indeterminate`
3. else (all `.running` / `.paused`) → the **least-complete** percent;
   `.running(min)` if any pane is running, else `.paused(min)`
4. nothing reporting → `.none`

"Least-complete" means the smallest percent, so the aggregate bar only
fills when every reporting pane is done. The precedence is implemented as a
pure reduction over `[PaneProgress]`, unit-tested independently of the tab.

### Rendering

Both sites read `tab.aggregateProgress` and share one small helper for the
state→color mapping (running = `Color.accentColor`, paused =
`Color.orange`, error = `Color.red`).

**Tab bar** (`TabBarItem`, `Mistty/Views/TabBar/TabBarView.swift`): the tab
is an `HStack` with a `.background(tabBackground)` and `.cornerRadius(5)`.
Add a `.overlay(alignment: .bottom)` that renders a 2pt bar inset to the
tab's rounded rect:
- `.running(p)` / `.paused(p)` / `.error(p)`: a background track (faint)
  with a fill whose width = `p%` of the tab width, in the state color.
- `.indeterminate`: a short segment animated left↔right (a repeating
  `withAnimation`), state color = accent.
- `.none`: nothing.

**Sidebar** (`SidebarTabRow`, `Mistty/Views/Sidebar/SidebarView.swift`):
the row already uses `.overlay(alignment: .leading)` for the activity
stripe and `.overlay(alignment: .top/.bottom)` for drop indicators. Mirror
the bar as a `.overlay(alignment: .bottom)` thin fill bar spanning the row
width, same color/percent semantics. The existing leading stripe and bell
treatment are unchanged.

The bar coexists with `hasBell` (orange background / stripe) and the
zoomed glyph — it occupies the bottom edge, which neither uses.

### Lifecycle / clearing

- `REMOVE` → `.none` (the conventional end signal).
- Pane close / surface exit: clear `pane.progress = .none` on the existing
  `.ghosttyCloseSurface` path so a dead pane can't leave a stale bar.
- A pane that survives its process (`close_on_exit = false`) and reached
  100% without `REMOVE` keeps a full bar until the next report or close —
  accepted for v1.

### Config

A single visibility toggle under the existing `[ui]` table, consistent
with `tab_bar_mode` / `title_bar_style` etc.:

```toml
[ui]
progress_bar = true   # default; false hides all progress indicators
```

- New `UIConfig.progressBar: Bool = true`, parsed from `[ui].progress_bar`,
  serialized in `save()` when non-default, documented in
  `docs/config-example.toml`.
- Both render sites gate on `MisttyConfig.current.ui.progressBar`. Live
  reload is free (views read `config`, which refreshes on
  `.misttyConfigDidReload`). The model still tracks `pane.progress`
  regardless; the toggle only governs rendering.

## Testing

Unit tests:

- **`paneProgress(state:percent:)` mapper** — every state; `SET` with a
  percent and with `-1`; `ERROR`/`PAUSE` with and without a percent;
  out-of-range clamping.
- **Aggregation reduction** — empty → `.none`; single running; error wins
  over running/indeterminate/paused; indeterminate over running/paused;
  least-complete percent selection; all-paused → `.paused(min)`; `.none`
  panes ignored.
- **`UIConfig.progressBar`** — default `true`; explicit `false`; missing
  `[ui]` table; `save()` round-trip.

Manual verification (the action callback and SwiftUI rendering aren't
unit-testable):

- `printf '\e]9;4;1;45\a'` → tab bar + sidebar show a ~45% accent bar.
- `;1;100` → full; `;0` → clears.
- `;2;` → red (error); `;3` → animated indeterminate; `;4;60` → amber paused.
- Two split panes reporting different percents → tab bar shows the
  least-complete; error in one pane turns the tab bar red.
- Tab-bar-hidden + sidebar-open → sidebar bar still shows.
- `[ui] progress_bar = false` + reload → indicators disappear; the model
  still tracks (re-enable shows the live value).
- Close a pane mid-progress → bar clears.

## Out of scope (recap)

Dock progress, window-title percent, progress history/persistence,
auto-timeout, and any libghostty changes.
