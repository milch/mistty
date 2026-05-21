# OSC desktop notifications — OSC 9 / OSC 777

Date: 2026-05-21
Status: Design

## Problem

A foreground program in a pane can ask the terminal to raise a desktop
notification ("build finished", "tests passed", "@you on call"). Mistty
currently drops these. Two notification OSC sequences are in scope:

- **OSC 9** — `ESC ] 9 ; message ST` — the iTerm2-style fallback. Empty
  title, `message` as the body.
- **OSC 777** — `ESC ] 777 ; notify ; title ; body ST` — rxvt's extension
  with both a title and a body.

The vendored libghostty already parses both into a single
`desktop_notification` action — Mistty just never handles it. The action
falls through the `default` case of the runtime action callback and
returns `false`.

OSC 99 (Kitty's notification protocol) is **out of scope** — see Non-goals.

## Non-goals

- **OSC 99 (Kitty protocol).** The vendored ghostty has no OSC 99 parser
  (only an encoding-validation reference in `src/terminal/osc/encoding.zig`).
  Supporting it needs a sizable Zig patch — a new OSC parser plus action
  plumbing — and the protocol is much richer (icons, action buttons,
  urgency levels, identifiers, chunked payloads). Deferred to a separate
  spec. Tracked as a PLAN.md follow-up.
- **Settings-pane toggle.** The `[notifications]` config is the only knob
  for now. A Settings UI control is deferred to the preference-pane
  redesign — same precedent as the configurable-shortcuts feature.
- **Notification sound, per-session muting, notification history/center
  UI, action buttons, icons.** None of these are needed for the core
  feature.
- **Mistty-side rate limiting or de-duplication.** libghostty already
  rate-limits to 1 notification/sec globally and de-dupes identical
  content within a 5 s window (`Surface.showDesktopNotification`). Mistty
  adds none.

## Background — what libghostty already gives us

- `osc.zig` + `parsers/osc9.zig` parse OSC 9 / OSC 777 into a
  `show_desktop_notification` command.
- `Surface.showDesktopNotification` rate-limits + de-dupes, then calls
  `performAction` with a `desktop_notification` action.
- The C API exposes this as `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`
  (`ghostty.h`), payload `ghostty_action_desktop_notification_s { const
  char* title; const char* body; }`. Title is capped at 63 bytes, body at
  255 bytes, both NUL-terminated and truncated upstream.
- The action is surface-targeted, so it carries the originating surface —
  Mistty can map it back to a `MisttyPane` via the established
  `ghostty_surface_userdata` → `TerminalSurfaceView` → `pane` chain.
- The action only fires when ghostty's own `desktop-notifications` option
  is enabled. That option defaults to `true` and Mistty does not override
  it, so no config wiring is required on that side.

No vendored-ghostty changes are needed for this feature.

## Design

### Architecture

A single global `NotificationService` owns the macOS notification
integration. The `GhosttyApp.swift` action callback posts a
`NotificationCenter` event; the service consumes it **exactly once**.

A global singleton (rather than handling this in `ContentView` next to
`handleRingBell`) is required because `UNUserNotificationCenter.add()` is
not idempotent: if every window's `ContentView` received the event, N
windows would raise N duplicate banners. The bell handler tolerates the
fan-out only because its effects (`hasBell = true`, dock-badge recompute)
are idempotent.

### Data flow

1. A program emits `ESC]9;msg ST` or `ESC]777;notify;title;body ST`.
2. libghostty parses, rate-limits + de-dupes, fires
   `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` (surface-targeted) with
   `{ title, body }`.
3. New `case` in `actionCallback` (`Mistty/App/GhosttyApp.swift`):
   - Convert `title` / `body` from C strings to Swift `String`
     **synchronously**, inside the callback — the `action` struct is only
     valid for the duration of the callback. Capture the `String`s.
   - Read `ghostty_surface_userdata(surface)` →
     `Unmanaged<TerminalSurfaceView>` → `view.pane?.id`.
   - `DispatchQueue.main.async` → post `.ghosttyDesktopNotification` with
     userInfo `{ paneID, title, body }`.
4. `NotificationService` (a `NotificationCenter` observer) consumes it.

### `NotificationService`

New file in the main app target, alongside the existing services.
Singleton; created at app launch and set as
`UNUserNotificationCenter.current().delegate`. Conforms to
`UNUserNotificationCenterDelegate`.

On `.ghosttyDesktopNotification`:

1. **Config gate.** If `MisttyConfig.current.notifications.enabled` is
   `false`, drop. Read live each time, so config reload takes effect with
   no extra wiring.
2. **Resolve the pane** via the global `WindowsStore.pane(byId:)`.
3. **Compute `isFocused`** — Mistty is frontmost (`NSApp.isActive`) ∧ the
   pane's window is key ∧ the pane is the active pane of the active tab of
   the active session. This mirrors `ContentView.handleRingBell`'s
   visibility check. Extract the decision as a pure boolean helper
   (inputs: `appActive`, `windowKey`, `sessionActive`, `tabActive`,
   `paneActive`) so it is unit-testable.
4. **If `isFocused`** → no-op. The user is already looking at the pane
   that fired it; no banner, no tab flag. (Same principle as the bell.)
5. **Else:**
   - `tab.hasBell = true` and `windowsStore.updateDockBadge()` — reuses
     the existing orange tab activity indicator and dock badge.
   - Lazily call `requestAuthorization(options: [.alert])` the first time
     the service needs to post (tracked by an internal flag so it is
     requested once).
   - Build a `UNMutableNotificationContent`:
     - `title` = resolved title (see Title resolution).
     - `body` = the OSC body.
     - `threadIdentifier` = the session id (string) — groups multiple
       notifications from the same session in Notification Center.
     - `userInfo` = `{ paneID }`.
     - `sound` = `nil` (silent; audio is the bell's job).
   - `UNUserNotificationCenter.current().add(request)` with a fresh UUID
     request identifier.

### Delegate callbacks

- `userNotificationCenter(_:willPresent:)` → return `[.banner, .list]`.
  Every notification the service posts has already passed the
  `isFocused` check, so it always deserves a banner — including the case
  where Mistty is frontmost but the user is on a *different* pane or
  window. (macOS otherwise routes frontmost-app notifications silently to
  Notification Center.)
- `userNotificationCenter(_:didReceive:)` (the user clicked the banner) →
  read `paneID` from `userInfo`, resolve via `WindowsStore.pane(byId:)`,
  then `NSApp.activate(ignoringOtherApps: true)`, bring the pane's window
  to front, and focus the window / session / tab / pane using the
  existing `focusPane` / `focusKeyboardInput` helpers.

### Title resolution

OSC 9 produces an empty title. An empty macOS notification title looks
broken, so resolve via a fallback chain (pure function — unit-tested):

1. The OSC title, if non-empty (OSC 777 path).
2. The pane / tab process title, if non-empty.
3. The session display name.
4. `"Mistty"`.

### Tab indicator + dock badge

Reuse the existing `tab.hasBell` orange activity indicator and the dock
badge — no new UI. A background OSC notification flags its tab exactly
like a bell does (per the agreed behavior).

`updateDockBadge()` currently lives on `ContentView`. Its body is purely
global state (`windowsStore.windows.flatMap(...)` → `NSApp.dockTile`),
so move it onto `WindowsStore` as `updateDockBadge()`. `ContentView`'s
existing call sites become `windowsStore.updateDockBadge()`;
`NotificationService` calls the same method. Small, justified extraction.

### Config

New `[notifications]` table in `config.toml`:

```toml
[notifications]
enabled = true   # default
```

- New `NotificationsConfig { enabled: Bool }` value type, default
  `enabled = true`, parsed by `MisttyConfig` like the other config
  sections. A missing `[notifications]` table yields the default.
- Live reload: `NotificationService` reads `MisttyConfig.current` at
  event time, so the existing `MisttyConfig.reload()` path covers it with
  no extra observers.
- Documented in `docs/config-example.toml`.

## Behavior summary

| Situation | Banner? | Tab flagged? |
| --- | --- | --- |
| Emitting pane is the focused pane, Mistty frontmost | no | no |
| Emitting pane in a background tab/window, Mistty frontmost | yes | yes |
| Mistty backgrounded | yes | yes |
| `[notifications] enabled = false` | no | no |
| Notification permission denied | no | yes |

Click a banner → Mistty activates and focuses the emitting pane.

## Error handling / edge cases

- **Empty OSC-9 title** → title-resolution fallback chain.
- **Pane no longer resolvable** — the pane closed between emission and
  main-thread dispatch, or (defensively) the action arrived APP-targeted
  rather than SURFACE-targeted. Skip the tab flag and still post a banner,
  just without a click-to-focus target (the click only activates Mistty).
  The action is expected to be surface-targeted; confirm the target tag
  during implementation.
- **Permission denied** — `add()` silently no-ops. The tab flag and dock
  badge still work, so the feature degrades gracefully.
- **Rate-limit / dedup** — handled entirely by libghostty; Mistty adds
  none.

## Testing

Unit tests:

- `NotificationsConfig` TOML parsing — default `true`, explicit `false`,
  and a missing `[notifications]` table.
- Title-resolution fallback function — OSC-777 title wins; empty title
  falls through process title → session name → `"Mistty"`.
- The `isFocused` / should-banner boolean helper across the input matrix.

Manual verification (the libghostty action callback and
`UNUserNotificationCenter` cannot be unit-tested):

- `printf '\e]9;hello\a'` from a **background** pane → banner with a
  resolved title; tab gets the orange indicator; dock badge increments.
- `printf '\e]777;notify;Build;done\a'` from a background pane → banner
  titled "Build", body "done".
- Same from the **focused** pane → no banner, no tab flag.
- Click a banner → Mistty activates and focuses the emitting pane.
- `[notifications] enabled = false`, reload config → notifications
  suppressed without a restart.
- First notification on a clean install → macOS permission prompt.

## Follow-ups

- **OSC 99 (Kitty notification protocol)** — needs a libghostty Zig
  parser patch plus action plumbing; richer payload (icons, action
  buttons, urgency, identifiers, chunked encoding). Separate spec.
- Settings-pane toggle for `[notifications]`, folded into the
  preference-pane redesign.
- Optional notification sound, per-session muting.
