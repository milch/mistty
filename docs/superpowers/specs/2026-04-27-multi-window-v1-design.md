# Multi-Window v1

**Status:** design
**Date:** 2026-04-27
**Scope:** v1 — fix the multi-window bug by giving each terminal window its own
independent sessions, tabs, and panes.

## Goal

Make `Cmd+N` open a fresh terminal window that doesn't disturb the existing
window's state. Each window owns its own sessions, tabs, panes, sidebar
selection, active markers, and Cmd+J results. No shared scope between windows
beyond the dock badge, app config, and global services (zoxide, SSH config,
frecency).

## Non-goals (v1)

- Moving sessions/tabs/panes between windows (Arc-style cross-window
  drag/drop). v2.
- Per-window NSWindow encoding via AppKit's `encodeRestorableState` — saved as
  a v2+ followup in PLAN.md so window frames/positions can ride per-scene
  storage.
- Replacing SwiftUI's `WindowGroup` with explicit `NSWindowController`s — saved
  as a v2+ followup. The data model below carries over unchanged when/if we
  switch.
- Per-window popup definitions (popups already attach to sessions, which are
  per-window now — no separate config needed).
- "Window menu" listing all windows for jump-to-window navigation.

## User-facing behavior

- `Cmd+N` (already wired by `WindowGroup`): spawn an empty window. No
  pre-populated session — shows the existing "Press ⌘J to open or create a
  session" placeholder.
- Each window's sidebar shows only that window's sessions.
- `Cmd+J` in window A: "Running sessions" lists only A's sessions. Zoxide and
  SSH config still feed all candidate suggestions globally.
- `Cmd+1..9` / `Ctrl+1..9` / `Cmd+]/[` / `Cmd+Shift+↑/↓` / `Cmd+Opt+↑/↓` all
  scope to the focused window.
- Bell ring in any window's background tab increments the single dock badge.
  Switching to that tab in that window clears its contribution.
- `Cmd+W` closes a pane in the focused window only.
- Closing the last terminal window does not quit the app
  (`applicationShouldTerminateAfterLastWindowClosed → false`). Cmd+N spawns a
  fresh empty window.
- Quit + relaunch restores all windows with their sessions/tabs/panes/active
  markers.
- Close a window mid-session: the window is added to an in-memory
  recently-closed stack. New menu item **Reopen Closed Window** (`Cmd+Shift+T`)
  re-spawns the most recent.
- Close all windows + Cmd+Q + relaunch: opens one fresh empty window. Closed
  windows that were dismissed before the quit are not restored (`Cmd+Q` snapshot
  is `windows: []`).

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────┐
│  WindowsStore (@Observable, app-singleton, @State on MisttyApp)  │
│   ├── windows: [WindowState]                                     │
│   ├── activeWindow: WindowState?  (mirrors NSApp.keyWindow)      │
│   ├── nextWindowID / nextSessionID / nextTabID / nextPaneID /    │
│   │   nextPopupID  (global counters)                             │
│   ├── trackedNSWindows: [(id, NSWindow, WindowState)]            │
│   ├── pendingRestoreStates: [WindowState]  (FIFO restore queue)  │
│   ├── recentlyClosed: [WindowSnapshot]     (Cmd+Shift+T undo)    │
│   ├── openWindowAction: OpenWindowAction?  (captured at mount)   │
│   ├── lookups: session/tab/pane/popup(byId:)                     │
│   ├── focusedWindow() / isTerminalWindowKey()                    │
│   └── isActiveTerminalWindow(state:): per-window key guard       │
│                                                                  │
│  WindowState (@Observable, one per terminal window)              │
│   ├── id                                                         │
│   ├── sessions: [MisttySession]                                  │
│   ├── activeSession + lastActivatedAt didSet                     │
│   └── session-scoped methods relocated from SessionStore         │
│                                                                  │
│  WindowRootView (SwiftUI WindowGroup root)                       │
│   ├── @State windowState: WindowState?                           │
│   ├── onAppear: claim pendingRestoreStates.first or createWindow │
│   ├── WindowAccessor → windowsStore.registerNSWindow             │
│   └── hosts ContentView(state:, windowsStore:, config:)          │
│                                                                  │
│  ContentView (per-window root view)                              │
│   ├── reads state.sessions / state.activeSession                 │
│   ├── cross-window lookups via windowsStore.pane(byId:) etc.     │
│   └── dock badge + bell route via windowsStore                   │
└──────────────────────────────────────────────────────────────────┘
```

`SessionStore` no longer exists as a single type. Its session-management
responsibilities relocate to `WindowState`; its window-tracking and ID-counter
responsibilities relocate to `WindowsStore`.

## ID strategy

- `nextSessionID`, `nextTabID`, `nextPaneID`, `nextPopupID` live on
  `WindowsStore` and stay globally unique across windows. `MisttySession.init`
  closes over `windowsStore.generate*ID()` so existing call sites keep working.
- `nextWindowID` is new. Window IDs are also globally unique. Stable across
  restart (persisted in the snapshot).
- `WindowsStore.session(byId:)` etc. iterate all windows and return the
  matched entity plus its owning `WindowState`. Pure global lookup matches
  current behavior — IPC's `focusPane id` from any context works regardless of
  which window the pane lives in.

## Notification routing & key-window scoping

Today `MisttyApp.body.commands` posts ~25 actions to `NotificationCenter.default`
that every `ContentView` receives, and `ContentView` installs ~7 app-level
`NSEvent.addLocalMonitorForEvents` monitors. With one window that's fine; with
N windows each notification fires N times and each event fires N monitors.

The fix is uniform — guard each handler on "is *this* window the active
terminal window?" rather than refactoring the bus:

**Active-window filter** — `WindowsStore` exposes
`isActiveTerminalWindow(state:) -> Bool` returning `true` iff the tracked
NSWindow for `state` is `NSApp.keyWindow`. (The existing
`isTerminalWindowKey()` answers "*some* terminal window is key" — kept for
the menu's auxiliary-window-handling path; the new method answers "*this
specific* window is key.")

**(a) Window-scoped command notifications** (new tab, splits, copy mode,
window mode, yank hints, session manager, Cmd+W close pane/tab, rename
tab/session, popup toggle, focus tab/session by index, next/prev tab/session,
move session up/down): `ContentView.onReceive(NotificationCenter...)` handlers
add a `guard windowsStore.isActiveTerminalWindow(state: state) else { return }`
at the top. The notification still broadcasts; only the active window's
ContentView acts.

**(b) Pane-targeted notifications from libghostty** (`ghosttySetTitle`,
`ghosttyRingBell`, `ghosttyPwd`, `ghosttyCloseSurface`): each carries a
`paneID`. ContentView resolves via `windowsStore.pane(byId:)`; if the pane's
owning window isn't `state`, no-op. (Bell handling is the only one with
cross-window side effects — it still updates the global dock badge through
`windowsStore`.)

**(c) NSEvent local monitors** (`closeMonitor`, `windowModeShortcutMonitor`,
`ctrlNavMonitor`, `altShortcutMonitor`, `windowModeMonitor`,
`copyModeMonitor`, `eventMonitor`/session-manager): each gains the same
`isActiveTerminalWindow` guard at the top. Returns `event` unchanged when
not active so the focused window's monitor still runs.

After the refactor, `rg "NotificationCenter\.default\.publisher\(for: \.mistty"`
still has matches in `ContentView` — but every match has an
`isActiveTerminalWindow` guard. The audit pattern is "every misttty-action
handler must be guarded." A test or runtime assertion that a notification was
processed by exactly one ContentView (when ≥1 window is open) would catch
regressions.

## State restoration

### Schema (v2)

```swift
struct WorkspaceSnapshot: Codable {
  let version: Int  // = 2
  let windows: [WindowSnapshot]
  let activeWindowID: Int?
}

struct WindowSnapshot: Codable {
  let id: Int
  let sessions: [SessionSnapshot]
  let activeSessionID: Int?
  // v2+ optional slot — leave the field but defer wiring:
  // let frame: CGRect?
}
```

`SessionSnapshot`, `TabSnapshot`, `LayoutNodeSnapshot`, `PaneSnapshot`,
`CapturedProcess` are unchanged.

### v1 → v2 migration

The decoder inspects `version` first:

- `version == 1` (or any payload missing `windows` but having a top-level
  `sessions` array): synthesize `WindowSnapshot { id: 1, sessions:
  decoded.sessions, activeSessionID: decoded.activeSessionID }` and wrap in a
  `WorkspaceSnapshot { version: 2, windows: [migrated], activeWindowID: 1 }`.
  Bumps `nextWindowID` to 2.
- `version == 2`: use as-is.
- Other versions: bail to empty (existing behavior preserved).

### Encode flow

`AppDelegate.application(_:willEncodeRestorableState:)` calls
`windowsStore.takeSnapshot()`, which iterates `windows` and emits a
`WorkspaceSnapshot v2` keyed under the existing AppKit storage slot. Empty
`windows` array snapshots fine — relaunch reads it and creates one fresh
window.

### Decode flow

`AppDelegate.application(_:didDecodeRestorableState:)`:

1. Decode `WorkspaceSnapshot` (with v1 → v2 migration if needed).
2. `windowsStore.restore(snapshot, config: RestoreConfig.fromMisttyConfig())`:
   - Build one `WindowState` per `WindowSnapshot`, hydrate its sessions via
     the existing `restoreLayoutNode` machinery (relocated from
     `SessionStore+Snapshot` to `WindowsStore+Snapshot`).
   - Set each window's `activeSession`.
   - Advance global ID counters past all observed IDs.
   - Push the resulting `WindowState`s onto `windowsStore.pendingRestoreStates`
     in snapshot order.
3. Stash `snapshot.activeWindowID` for post-mount focus.

### Window spawning during restore

SwiftUI's `WindowGroup` auto-spawns one window on launch. That window's
`WindowRootView.onAppear`:

1. Captures `Environment(\.openWindow)` into `windowsStore.openWindowAction`
   (idempotent).
2. Claims `pendingRestoreStates.first` if non-empty, else
   `windowsStore.createWindow()`.
3. Calls `windowsStore.drainPendingRestores()`: for each remaining queued
   state, fire `openWindowAction()` once.

Each subsequent mounting `WindowRootView` claims the next pending state from
the queue. When the queue is empty, future Cmd+N spawns a fresh empty
`WindowState`.

After all spawns, `windowsStore.activeWindow = state(forID: stashedActiveID)`
and that window's tracked NSWindow is sent `makeKeyAndOrderFront(nil)`.

### Recently-closed stack

`windowsStore.closeWindow(state)` snapshots the window's state into
`recentlyClosed: [WindowSnapshot]` (in-memory only — wiped at app quit).
Capacity capped at e.g. 10. Menu item **Reopen Closed Window** (`Cmd+Shift+T`)
pops the head, re-hydrates a `WindowState`, pushes onto `pendingRestoreStates`,
fires `openWindowAction()`.

### First launch (no saved state)

On a fresh launch with no saved state, `WindowGroup` auto-spawns one window;
`WindowRootView.onAppear` finds `pendingRestoreStates` empty and calls
`windowsStore.createWindow()`. The fresh `WindowState` is empty —
`activeSession == nil` — and `ContentView` shows the existing "No active
session — Press ⌘J to open or create a session" placeholder. This matches
today's first-launch behavior; no separate "default session" creation runs.
Cmd+N spawns additional empty windows the same way.

## IPC

### Response models

`SessionResponse`, `TabResponse`, `PaneResponse`, `PopupResponse` gain a
`window: Int` field — the owning window's id. JSON consumers see the new key;
human-readable formatter adds a `Window` column. Backward-incompatible for
external CLI scripts; safe to change since `mistty-cli` is internal.

### Read endpoints

`listSessions`, `listTabs`, `listPanes`, `listPopups`, `getSession`, `getTab`,
`getPane`, `getPopup` iterate `windowsStore.windows`, flatten, attach `window`
field. Behavior is "global view across all windows" — matching the user's
specification: read ops stay global, only creates need window context.

### Mutating endpoints by global ID

`closeSession`, `closeTab`, `closePane`, `focusPane`, `focusPaneByDirection`,
`resizePane`, `sendKeys`, `runCommand`, `getText`, `renameTab`, `closePopup`,
`togglePopup` resolve by global ID via `windowsStore.session(byId:)` etc. No
`--window` flag.

`focusPane` and `focusSession`: when the target lives in a non-key window,
the handler additionally calls
`tracked.window.makeKeyAndOrderFront(nil)` so the user sees the result.

### `createSession`

Window resolution priority:

1. `--window <id>` flag → `windowsStore.window(byId:)` (404 if not found).
2. `windowsStore.focusedWindow()` — the tracked terminal window whose NSWindow
   is `NSApp.keyWindow`.
3. Error: `no focused window; pass --window <id>`.

Once resolved, calls `targetWindow.createSession(...)`. CLI gains an optional
`--window <id>` flag on the `session create` ArgumentParser command. The
`MisttyIPC.createSession` payload gains an optional `windowID: Int?`.

The `MISTTY_WINDOW` env var is **not** introduced. The user's reasoning: a
script invoked from a pane in a backgrounded window probably doesn't intend to
target that window — defaulting to the focused window matches the interactive
case. Scripts that need deterministic targeting pass `--window` explicitly.

### `createWindow`

Currently returns "Not supported". Now:

1. `let id = windowsStore.reserveNextWindowID()` synchronously.
2. `let state = WindowState(id: id, ...)` — empty sessions.
3. `windowsStore.pendingRestoreStates.append(state)` so the new view claims it.
4. `windowsStore.openWindowAction?()` — fire the spawn.
5. Return `WindowResponse { id, sessionCount: 0 }`.

If `openWindowAction` is nil (e.g. RPC arrives before the first window has
mounted), error: `IPC not yet ready; first window must mount before
createWindow can spawn additional windows`.

### `closeWindow` / `focusWindow`

Already implemented. No behavioral change beyond the registry move:

- `closeWindow id`: looks up `(NSWindow, WindowState)` via
  `windowsStore.trackedNSWindow(byId:)`, calls `nsWindow.close()`,
  `windowsStore.unregisterNSWindow(nsWindow)`, snapshots into `recentlyClosed`.
- `focusWindow id`: `tracked.window.makeKeyAndOrderFront(nil)`.

## Edge cases & lifecycle

- **Cmd+W routing**: `closeMonitor` and the menu Close Pane button gate on
  `windowsStore.isTerminalWindowKey()`. The notification (or new direct
  dispatch) targets `windowsStore.activeWindow` so Cmd+W closes a pane in the
  focused window only.
- **Bell propagation**: `handleRingBell` resolves the pane via
  `windowsStore.pane(byId:)` and marks `tab.hasBell = true` only when the
  resolved tab isn't the active tab of the active session of *its owning
  window*. Switching focus between windows doesn't clear bells in the previous
  window — bells clear when the user activates the bell-ringing tab
  specifically.
- **`StateRestorationObserver`**: re-rooted at `windowsStore`. The
  `withObservationTracking` registration walks `windowsStore.windows` (and
  each window's sessions/tabs/panes) on every fire. AppKit coalesces
  `invalidateRestorableState()` regardless.
- **NSView surface migration**: still single-NSView per pane. Panes are
  immutable per window in v1 (no cross-window moves), so the existing
  reparenting hazards don't apply. v2 cross-window moves will need explicit
  NSView removal/re-add coordination — flagged for that design.
- **Session-manager focus return**: `showingSessionManager.onChange` calls
  `returnFocusToActivePane()` against `state.activeSession?.activeTab?.activePane`,
  same as today but window-scoped.
- **AppDelegate properties**: `appDelegate.store` becomes
  `appDelegate.windowsStore`. `appDelegate.observer` re-rooted likewise.

## Testing

### Unit tests (Swift Testing)

- `WorkspaceSnapshotMigrationTests`: a v1 payload (existing fixture or
  hand-crafted JSON) decodes into a v2 single-window snapshot; round-trips
  through encode-as-v2 unchanged on second pass.
- `WindowsStoreLookupTests`: `session(byId:)` / `tab(byId:)` / `pane(byId:)`
  find entities across multiple windows; correct owning `WindowState`.
- `WindowsStoreLifecycleTests`: `createWindow` then `closeWindow` removes from
  `windows` and `trackedNSWindows`; `recentlyClosed` populated.
- `WindowStateSessionManagementTests`: relocated coverage from existing
  `SessionStore` tests — nothing new behaviorally, just moved.
- `IPCServiceWindowResolutionTests`: `createSession` with `--window` (success,
  not-found), with focused-window fallback (success), with neither (errors).

### Manual UI walkthrough (release gate)

1. Cmd+N spawns empty window; original window's panes stay where they are.
2. Two windows side-by-side, multiple sessions/tabs/panes each — keystrokes
   route to focused window only.
3. Bell ring in background window of background tab → dock badge increments;
   switching to that tab in that window clears it.
4. Cmd+J in window A shows only A's running sessions; opening a "running"
   entry from B's list (typed as path) creates an independent session in A.
5. Cmd+W closes pane in focused window only; other window untouched.
6. Quit with multiple windows; relaunch; all windows + states + active
   markers restore.
7. Close all windows; Cmd+Q; relaunch; one fresh empty window appears.
8. Close one of two windows; Cmd+Shift+T; closed window re-spawns with state
   intact.
9. `mistty-cli session list` returns sessions from both windows with `window`
   field populated.
10. `mistty-cli session create --name foo` while window B is focused → session
    lands in B. With Settings focused (no terminal window key), errors with
    "no focused window".
11. `mistty-cli window create` returns a fresh window-id; new window appears
    empty.
12. v1 snapshot in `~/Library/Saved Application State/...`: quit a v0.8.4
    build, install the v1-multi-window build, launch — single window with all
    prior sessions appears (migration path).

## Risks & mitigations

- **NotificationCenter refactor blast radius**: ~25 listeners. Mitigation:
  catalog them all in the implementation plan, convert as a single mechanical
  pass, then `rg "NotificationCenter\.default\.publisher\(for: \.mistty"` in
  ContentView — should return only the libghostty group (b) listeners.
- **SwiftUI `openWindow` timing**: capture happens on first window mount.
  Restoration's `drainPendingRestores()` runs inside the first
  `WindowRootView.onAppear` after it claims its own state, so the action is
  always non-nil by the time it's needed. Documented invariant in code.
- **`StateRestorationObserver` re-rooting**: `Observable` propagates correctly
  across nested `@Observable` types, but worth verifying snapshot writes
  coalesce across rapid multi-window mutations. Manual test: rapid splits in
  two windows simultaneously → AppKit fires one encode pass, not two.
- **App-level Cmd+Q encoding with multiple windows**: we still use the single
  app-level encode hook, enumerating all windows on each pass. Swimming
  against the AppKit grain — flagged as the constraint motivating the v2
  per-NSWindow encoding followup.
- **`WindowState` retain cycles**: ID-generator closures on `MisttySession`
  capture `windowsStore` weakly (existing pattern uses `[weak self]`). Verify
  windows can deinit when closed.

## v2+ followups (PLAN.md)

- Per-NSWindow encoding (option (b) from Q3 in design discussion): each window
  encodes its own state via `NSWindow.encodeRestorableState(_:)`. Unlocks
  per-window frame/position persistence and removes the app-level single-blob
  encoding.
- Switch terminal windows from SwiftUI `WindowGroup` to AppKit
  `NSWindowController` (Approach B from design discussion): cleaner long-term
  for multi-window correctness; data model from v1 carries over unchanged.
  Worth doing if SwiftUI `openWindow` timing or restoration coordination
  starts hurting.
- Cross-window session/tab/pane moves (Arc-style drag/drop). Requires NSView
  reparenting coordination for `TerminalSurfaceView`.
- Window menu listing all open windows for jump-to-window navigation.
- Per-window names/titles (custom title bar text).
