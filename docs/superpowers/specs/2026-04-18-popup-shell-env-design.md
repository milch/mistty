# Popup shell & env overrides

Date: 2026-04-18
Status: Design

## Problem

Popup windows today launch whatever shell ghostty spawns by default — on
macOS, this is the user's login shell (zsh with `-l`). Login shells read
`/etc/zprofile`, `~/.zprofile`, `~/.zshrc`, and often bounce through Homebrew's
`path_helper` shims, adding hundreds of milliseconds before the popup's command
runs. For transient popups (`lazygit`, a scratch shell, `btop`, etc.), that
startup cost is painful.

Users want:

1. A way to pick a lighter-weight shell per popup (e.g. `/bin/sh` or `dash`).
2. A way to set environment variables on that shell — because a bare
   `/bin/sh` won't inherit the full login-shell `PATH`, so the popup's
   `command` may not resolve.

## Non-goals

- No global "default popup shell" setting. Per-popup only — the mental model
  is simpler and the config ergonomics are fine (popups are few).
- No `shell_args` field. If a user needs flags, they use a different shell.
- No env-var editor in the Settings SwiftUI form for this pass (TOML only).
  Listed as a follow-up; popup editor is already dense and dictionary UIs add
  complexity disproportionate to the need.
- No ad-hoc shell override when `close_on_exit = false`. In that mode the
  popup's `command` IS the process ghostty spawns — there's no shell in the
  chain to override.

## Data model

Two optional fields on `PopupDefinition`:

```swift
struct PopupDefinition: Codable, Sendable, Equatable {
  var name: String
  var command: String
  var shortcut: String?
  var width: Double
  var height: Double
  var closeOnExit: Bool
  var shell: String? = nil        // NEW
  var env: [String: String] = [:] // NEW
}
```

`MisttyPane` gains matching storage (`shell: String?`, `env: [String: String]`),
populated by `MisttySession.openPopup` / `togglePopup` from the definition.
These flow into `TerminalSurfaceView.init` at the same point as today's
`command` / `initialInput`.

## TOML syntax

```toml
[[popup]]
name = "scratch"
command = "nvim"
shell = "/bin/sh"
env = { PATH = "/usr/local/bin:/usr/bin:/bin", TERM = "xterm-256color" }
```

Parsing rules (`MisttyConfig.parse`):

- `shell`: optional string. Unset → nil → ghostty default.
- `env`: optional inline table. Values must be strings; non-string values
  (int, bool, array, nested table) are skipped silently. Missing/empty →
  empty dictionary.
- No validation of shell path existence or env key format — if `/bin/sh` is
  missing, ghostty's own spawn error surfaces to the popup, same as any other
  bad `command`.

Rendering rules (`MisttyConfig.rendered`):

- Emit `shell = "..."` when non-nil, escaped via existing `tomlEscape`.
- Emit `env = { A = "...", B = "..." }` when non-empty, with keys sorted
  alphabetically so saves from the UI don't churn the file. Values escaped
  via `tomlEscape`.
- Skip both lines entirely when unset / empty — keeps round-trips for popups
  that don't use these fields byte-identical.

## Ghostty surface wiring

`TerminalSurfaceView.init` accepts two new params:

```swift
init(
  frame: NSRect,
  workingDirectory: URL? = nil,
  command: String? = nil,
  initialInput: String? = nil,
  shell: String? = nil,        // NEW
  env: [String: String] = [:]  // NEW
)
```

Behavior:

- **`closeOnExit = true`**: caller already passes `command` as
  `initialInput` ("exec <cmd>\n"). If `shell` is set, use `shell` as
  `cfg.command` (overriding ghostty's default shell). If `shell` is nil,
  leave `cfg.command` unset — matches today's behavior.
- **`closeOnExit = false`**: `cfg.command = command` as today. `shell` is
  ignored. Caller already enforces this (passes `shell: nil` in that
  branch) so the surface view doesn't need a special case.
- **`env`**: always applies (both `closeOnExit` modes). When non-empty,
  build a `[ghostty_env_var_s]` with C-string pointers and set
  `cfg.env_vars` + `cfg.env_var_count`.

### Memory lifetime for env vars

The existing surface init keeps C strings alive by nesting `withCString`
closures around `ghostty_surface_new`. Adding N env pairs would require
2N+1 nested closures; the code already bends this pattern to its limit.

Instead, `strdup` every string (working dir, command, initial input, env
keys, env values) up front into `UnsafeMutablePointer<CChar>` values,
build the `[ghostty_env_var_s]` array from those pointers, call
`ghostty_surface_new`, then `free` everything in a `defer`. This
replaces the nested `withCString` ladder with a flat structure that
handles any combination of fields and arbitrary env counts.

Keep this local to `TerminalSurfaceView.swift` — no shared helper.

## Settings UI

`SettingsView.swift` popup editor adds one row for `shell`:

```swift
TextField("Shell (optional)", text: Binding(
  get: { config.popups[index].shell ?? "" },
  set: { config.popups[index].shell = $0.isEmpty ? nil : $0 }
))
.frame(width: 150)
```

Placement: new row under the existing Name/Command/Shortcut line, before
the Size sliders. No env editor this pass — env entries on disk are
preserved through the form's save path because `PopupDefinition` is a
round-trippable `Codable`/`Equatable` struct.

Follow-up (not in scope): add a disclosure-group env editor with + / -
rows for key/value pairs.

## CLI

`mistty-cli popup open` gains:

- `--shell <path>` — optional string.
- `--env KEY=VAL` — repeatable `@Option`. Malformed values (missing `=`,
  empty key) print an error and exit non-zero. Duplicate keys: last one
  wins (matches shell export semantics).

Both forward through the IPC call as new parameters.

## IPC protocol

`MisttyServiceProtocol.openPopup` signature extended:

```swift
func openPopup(
  sessionId: Int, name: String, exec: String,
  width: Double, height: Double, closeOnExit: Bool,
  shell: String?, env: [String: String],
  reply: @escaping (Data?, Error?) -> Void
)
```

`IPCListener.swift` `"openPopup"` dispatch reads the new fields from the
JSON payload. Unset `shell` / missing `env` decode as nil / empty dict —
backwards compatible with older CLI clients that don't send them. No
protocol version bump.

`IPCService.openPopup` constructs the `PopupDefinition` with the new
fields and calls `session.openPopup(definition:)` as today.

## Tests

New tests in `MisttyTests/Config/MisttyConfigTests.swift`:

- `test_parsesPopupShellAndEnv` — TOML with both fields populated; assert
  `definition.shell == "/bin/sh"` and `definition.env == [...]`.
- `test_popupShellEnvOmitted` — existing TOML without new fields still
  parses; `shell == nil`, `env == [:]`.
- `test_popupEnvIgnoresNonStringValues` — TOML with `env = { A = "x",
  B = 42, C = true }` → env contains only `A`.
- `test_roundTripPopupShellEnv` — parse → `config.rendered` → parse;
  resulting `PopupDefinition` equals the original.
- `test_roundTripPreservesEnvOrder` — env keys sort alphabetically in
  rendered output (deterministic).

CLI tests: check `MisttyTests/` for existing popup CLI tests; if present,
add cases for `--shell` and `--env KEY=VAL` parsing including malformed
input. If not present, defer (separate test harness needed, out of scope
for this change).

No new tests for `TerminalSurfaceView` — it's view-layer and currently
untested; the ghostty wiring is exercised manually via the app.

## Docs

`docs/config-example.toml` popup section: add two commented lines showing
`shell = "/bin/sh"` and `env = { PATH = "..." }` with a one-line
explanation each. Match the style of the existing commented defaults
throughout the file.

## Migration

None required. All new fields default to nil / empty, existing configs
parse and render identically.

## Risks & open questions

- **Bad `shell` path**: ghostty will fail to spawn and the popup surface
  will show an error state (or silently exit). Acceptable — we don't
  pre-validate paths; ghostty's error handling applies. Document the
  failure mode in the config-example comment.
- **Env var naming**: TOML table keys must be valid identifiers unless
  quoted. Users with unusual env var names (rare) can quote:
  `"WEIRD-NAME" = "val"`. No special handling needed.
- **Interaction with ghostty's global `env` passthrough**: the passthrough
  applies to every surface globally; popup `env` is per-surface. Both
  apply; per-surface wins for colliding keys (ghostty's existing behavior).
  No change needed.
