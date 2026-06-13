# Per-Process Clipboard-Read Permissions — Design

**Status:** approved (2026-06-13)

## Problem

OSC-52 lets a program running in a terminal pane *read* the system clipboard.
Mistty currently denies all such reads by default (a 2026-06 security fix), with
a single global opt-in `allow_clipboard_read = true` that turns reads on
everywhere. That's too coarse: a user may trust `nvim`'s clipboard sync but not
some other TUI. We want per-process control with an interactive prompt, while
keeping the safe-by-default posture.

Cmd+V paste is user-initiated and always allowed — this design only governs
program-initiated OSC-52 *reads*.

## Goals

- Global mode `allow | prompt | deny`, defaulting to `prompt`.
- Per-process overrides (keyed on the local foreground executable basename) that
  win over the global mode.
- An interactive prompt (when the effective mode is `prompt`) with five choices
  covering once / always / this-session for allow, and once / always for deny.
- Safe by default; never silently leak the clipboard.

## Non-goals

- Distinguishing remote programs over SSH. Over SSH the local foreground exe is
  `ssh`/`mosh`/`et`, so the rule/prompt keys on that — accepted (decided
  2026-06-13: distinguishing the remote side is impractical and out of scope).
- A "Deny in this session" option (omitted by decision; trivial to add later).
- A Settings UI for managing rules (rules are written by the prompt and editable
  by hand in `config.toml`; a management UI can come later).
- Governing OSC-52 *writes* or Cmd+V paste.

## Decisions (from brainstorming)

1. **Process identity:** local foreground executable basename
   (`ForegroundProcessResolver.current(for:)`), not the spoofable OSC title.
2. **Prompt UI:** `NSAlert.beginSheetModal(for:)` attached to the emitting pane's
   `NSWindow` — async completion fits libghostty's deferred clipboard request;
   non-blocking; window-scoped. (libghostty supports deferred completion: its own
   macOS app defers behind a sheet and calls
   `ghostty_surface_complete_clipboard_request` later.)
3. **Vocabulary:** unified `allow | prompt | deny` for both global and
   per-process (a per-process `prompt` can force a prompt even when global is
   `allow`/`deny`).

## Architecture

Pure decision core + thin `@MainActor` coordinator, mirroring this codebase's
established patterns (`SearchMatching`/`CopyModeYank` pure cores behind
`CopyModeController`; `ConfigStore` for observable state).

```
OSC-52 read in a pane
  → libghostty read_clipboard_cb  (hand clipboard, confirmed:false)
  → libghostty confirm_read_clipboard_cb  (GhosttyApp, bg thread)
        PASTE request          → complete(confirmed:true)              [unchanged]
        OSC_52_READ request    → hop to main →
              ClipboardPermissionCoordinator.shared.decide(...)
                 → ClipboardPermission.resolve(global, processRule, sessionOverride)
                     .allow → complete(content, confirmed:true)
                     .deny  → complete("",      confirmed:true)
                     .prompt → NSAlert sheet on pane window → on choice:
                                 complete(...) + persist/override per choice
```

### 1. Config model (`MisttyConfig`)

```swift
enum ClipboardReadMode: String, Sendable, Equatable { case allow, prompt, deny }

struct ClipboardProcessRule: Sendable, Equatable {
  var name: String           // exact local executable basename, e.g. "nvim"
  var mode: ClipboardReadMode
}

// new fields on MisttyConfig
var clipboardRead: ClipboardReadMode = .prompt
var clipboardProcessRules: [ClipboardProcessRule] = []
```

TOML:

```toml
# global; default "prompt"
allow_clipboard_read = "prompt"

[[clipboard.process]]
name = "nvim"
allow_clipboard_read = "allow"

[[clipboard.process]]
name = "sketchytui"
allow_clipboard_read = "deny"
```

- Parse top-level `allow_clipboard_read` as the mode string. **Migration:**
  tolerate the legacy bool shipped earlier — `true → .allow`, `false → .deny`;
  an unrecognized string falls back to `.prompt` (the default).
- Parse `[[clipboard.process]]` like `[[ssh.host]]`: array of tables, each with
  `name` + `allow_clipboard_read`. Skip entries missing `name` or with an
  unrecognized mode.
- `save()` round-trips both (top-level key only when ≠ default; the
  `[[clipboard.process]]` block when non-empty), using the existing `tomlEscape`.
- Resolution helper: `clipboardProcessRule(for exe: String) -> ClipboardReadMode?`
  — first exact-name match wins (mirrors `SSHConfig.resolveCommand(for:)`).

### 2. Pure decision core (`Mistty/Models/ClipboardPermission.swift`)

```swift
enum ClipboardPermission {
  /// Most specific wins: session override → per-process rule → global.
  static func resolve(
    global: ClipboardReadMode,
    processRule: ClipboardReadMode?,
    sessionOverride: ClipboardReadMode?
  ) -> ClipboardReadMode {
    sessionOverride ?? processRule ?? global
  }
}
```

Fully unit-tested across the precedence matrix. (The body is trivial today;
keeping it a named, tested function documents the precedence and gives a stable
seam if precedence grows more nuanced.)

### 3. Coordinator (`Mistty/Services/ClipboardPermissionCoordinator.swift`)

`@MainActor final class ClipboardPermissionCoordinator`, accessed as `.shared`,
configured with the `WindowsStore` at app start (same pattern as
`NotificationService.shared.start(windowsStore:)`).

State:
- `sessionOverrides: [Key: ClipboardReadMode]` keyed by `(sessionID, exeName)`,
  in-memory only, cleared when a session closes.

Entry point (called from the callback after the main-thread hop):
```swift
func decide(paneID: Int, surface: ghostty_surface_t, state: UnsafeMutableRawPointer,
            content: String)
```
1. Resolve `paneID` → `(window, session, pane)` via `windowsStore`; resolve the
   foreground exe via `ForegroundProcessResolver.current(for: pane)` (fallback
   name `"(unknown)"` if nil — still promptable/denyable).
2. `decision = ClipboardPermission.resolve(global: config.clipboardRead,
   processRule: config.clipboardProcessRule(for: exe),
   sessionOverride: sessionOverrides[key])`.
3. `.allow` → `complete(content)`. `.deny` → `complete("")`. `.prompt` →
   `presentPrompt(exe:, window:)`, then on the user's choice apply the effect
   table below and complete.

Guard: if the surface is gone by completion time (pane closed mid-prompt), treat
as deny (complete `""`), never touching a freed surface.

Persistence ("always"): build an updated `MisttyConfig` with the new/replaced
`ClipboardProcessRule`, set `MisttyConfig.current`, `save()` it, and post
`.misttyConfigDidReload` (keeps `ConfigStore` and any future Settings UI in
sync — same effect as a reload).

Session-override cleanup: `clearSession(_ sessionID:)` called from the
session-close path (`WindowState.closeSession` / `MisttySession` teardown).

### 4. Prompt (`NSAlert.beginSheetModal`)

Message: **"Allow `<exe>` to read your clipboard?"**
Informative: one line explaining a program in this pane is requesting clipboard
contents.

Buttons → effects:

| Button | Completes | Persists |
|---|---|---|
| Allow once | allow | — |
| Allow always | allow | per-process rule `allow` (config) |
| Allow in this session | allow | in-memory session override `allow` |
| Deny once | deny | — |
| Deny always | deny | per-process rule `deny` (config) |

Presented on the emitting pane's `NSWindow` (resolved via the tracked-window
registry). If that window can't be found, fall back to deny-once (don't leak
without a visible prompt).

### 5. Callback wiring (`GhosttyApp`)

`confirmReadClipboardCallback`: PASTE stays `complete(confirmed:true)` with the
content. The `default` (OSC-52 read) branch — currently the hardcoded
allow/deny on `allow_clipboard_read` bool — instead resolves `userdata → view →
pane.id`, retains the view across `DispatchQueue.main.async`, and calls
`ClipboardPermissionCoordinator.shared.decide(paneID:surface:state:content:)`.
The content string and `state` pointer are captured for deferred completion.

## Error / edge handling

- **Pane/window closed mid-prompt:** complete with `""` (deny); never touch a
  freed surface (guard `view.surface`).
- **Unknown foreground process:** prompt/deny using `"(unknown)"`; a persisted
  rule for `"(unknown)"` is allowed but unusual.
- **Concurrent OSC-52 reads:** each request gets its own callback/state; sheets
  queue naturally per window (AppKit serializes sheets on a window).
- **Config save failure:** the in-memory decision still applies for this request;
  log the save error (don't block the completion).
- **Legacy bool config:** migrated on parse; on next `save()` it's rewritten as
  the string form.

## Testing

- **`ClipboardPermissionTests`** (pure): full precedence matrix — session
  override beats process rule beats global; nil layers fall through; each mode
  returned correctly.
- **`MisttyConfigTests`** additions: parse global `allow|prompt|deny`; legacy
  `true`/`false` migration; unrecognized string → `.prompt`; `[[clipboard.process]]`
  parse; full save→load round-trip incl. process rules; `clipboardProcessRule(for:)`
  first-match-wins.
- **Coordinator decide()** resolution path can be tested for the allow/deny
  branches by injecting a fake foreground-process resolver and asserting the
  completion decision (without a live surface); the sheet branch and actual
  `NSAlert`/surface completion are **manual** (GUI).
- Manual: the five buttons; once vs always (persisted to `config.toml`) vs
  session (cleared on session close / relaunch); over-SSH wording; pane-closed
  -mid-prompt safety.

## Migration / compatibility

- The `allow_clipboard_read = true|false` bool shipped earlier (commit
  `ca7d268`, unreleased) is read as `.allow`/`.deny` and rewritten as a string on
  next save. The `MisttyConfig.allowClipboardRead: Bool` field and its
  `confirmReadClipboardCallback` check are **replaced** by `clipboardRead` +
  the coordinator. `MisttyConfigTests.test_allowClipboardRead_*` is updated to the
  new model.
