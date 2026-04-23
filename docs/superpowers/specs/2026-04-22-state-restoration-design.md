# State Restoration

**Status:** design
**Date:** 2026-04-22
**Scope:** v1 — auto-save workspace on quit, auto-restore on launch.

## Goal

Make Mistty wake up the way it quit: all sessions, tabs, and split panes back
in place, each pane's shell starting at the directory it was in, with a
configurable allowlist to relaunch specific programs (`nvim`, `claude`, `ssh`,
etc.). No scrollback in v1; structure only.

## Non-goals (v1)

- Scrollback preservation (no libghostty write-back API; punted).
- ANSI-styled scrollback.
- Named / user-saved layouts (future feature, additive — same schema).
- Popup state, copy/window/search mode state, zoomed-pane marker.
- Multi-window persistence (upstream bug; PLAN.md).
- Pipeline capture (`git log | less` → only the pipeline leader is captured).

## User-facing behavior

- Quit → relaunch restores the workspace.
- Hold Option on Quit → next launch is empty (standard macOS gesture).
- System Settings → General → "Close windows when quitting an app" is honored.
- Non-allowlisted panes restore as bare shells at the saved CWD — no relaunch
  of arbitrary commands.
- SSH session panes are captured as `ssh <args>` via the same foreground-process
  detection path as any other program. A suggested `[[restore.command]]
  match = "ssh"` entry in `docs/config-example.toml` makes SSH round-trips work
  out of the box; users who prefer a different strategy (e.g. attach to a
  remote tmux) just override the `strategy` field.
- `mistty-cli debug state` dumps the current workspace snapshot as JSON.

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────┐
│  AppKit state restoration (system-owned save/restore triggers)   │
│   ├── AppDelegate (NSApplicationDelegate)                        │
│   │   • applicationSupportsSecureRestorableState → true          │
│   │   • application(_:willEncodeRestorableState:)  encodes Data  │
│   │   • application(_:didDecodeRestorableState:)   decodes Data  │
│   └── App-level encoding (one blob, not per-window)              │
│                                                                  │
│  SessionStore (existing)                                         │
│   ├── takeSnapshot() -> WorkspaceSnapshot            (new)       │
│   ├── restore(from:config:)                          (new)       │
│   └── StateRestorationObserver                       (new)       │
│       observes mutations → NSApp.invalidateRestorableState()     │
│                                                                  │
│  MisttyShared/Snapshot/  (new module)                            │
│   ├── WorkspaceSnapshot     version, sessions, activeSessionID   │
│   ├── SessionSnapshot       id/name/customName/dir/ssh/tabs/...  │
│   ├── TabSnapshot           id/customTitle/dir/layout/active     │
│   ├── PaneSnapshot          id/dir/liveCWD/captured?             │
│   ├── CapturedProcess       executable + argv                    │
│   └── LayoutNodeSnapshot    .leaf(pane) | .split(...)            │
│                                                                  │
│  Mistty/Support/ForegroundProcess.swift   (new)                  │
│   • resolves pane → foreground executable basename + argv        │
│   • primary: tcgetpgrp(pty_fd)         via ghostty patch C       │
│   • fallback: walk descendants of shell PID  via patch B         │
│                                                                  │
│  patches/ghostty/                                                │
│   ├── 0002-expose-shell-pid.patch                                │
│   └── 0003-expose-pty-slave-fd.patch                             │
│                                                                  │
│  MisttyCLI                                                       │
│   └── mistty-cli debug state   (dumps live snapshot as JSON)     │
└──────────────────────────────────────────────────────────────────┘
```

**Storage:** system-managed via AppKit
(`~/Library/Saved Application State/<bundleID>.savedState/`). Dev vs release
isolated because bundle IDs already differ (`bbf196e`).

**Why app-level, not per-window, encoding:** one workspace blob; multi-window
is broken upstream. When fixed, migrate to per-window encoding by splitting
`WorkspaceSnapshot.sessions` across windows — no schema change needed.

## Snapshot schema

```swift
public struct WorkspaceSnapshot: Codable, Sendable {
  public let version: Int                  // 1; decoder bails on unknown
  public var sessions: [SessionSnapshot]   // order = sidebar order
  public var activeSessionID: Int?
}

public struct SessionSnapshot: Codable, Sendable {
  public let id: Int
  public var name: String
  public var customName: String?
  public var directory: URL
  public var sshCommand: String?
  public var lastActivatedAt: Date
  public var tabs: [TabSnapshot]           // order = tab order
  public var activeTabID: Int?
}

public struct TabSnapshot: Codable, Sendable {
  public let id: Int
  public var customTitle: String?          // NOT the live OSC-2 title
  public var directory: URL?               // tab's initial directory
  public var layout: LayoutNodeSnapshot
  public var activePaneID: Int?
}

public struct PaneSnapshot: Codable, Sendable {
  public let id: Int
  public var directory: URL?               // initial dir
  public var currentWorkingDirectory: URL? // live OSC 7 at save; used on restore
  public var captured: CapturedProcess?    // nil ⇒ bare shell on restore
}

public struct CapturedProcess: Codable, Sendable {
  public var executable: String            // basename, e.g. "nvim"
  public var argv: [String]                // incl. argv[0]
}

public indirect enum LayoutNodeSnapshot: Codable, Sendable {
  case leaf(pane: PaneSnapshot)
  case split(direction: SplitDirectionSnapshot,
             a: LayoutNodeSnapshot,
             b: LayoutNodeSnapshot,
             ratio: Double)
}

public enum SplitDirectionSnapshot: String, Codable, Sendable {
  case horizontal
  case vertical
}
```

### Schema design choices

- **Panes live inside the layout tree.** The domain model's
  `MisttyTab.panes` is always `layout.leaves`; the snapshot collapses this
  redundancy to a single representation. On restore, `panes = layout.leaves`.
- **Strategy resolved at restore time, not save time.** Snapshot records
  `executable` + `argv`; allowlist lookup happens when rebuilding the pane. A
  user editing `config.toml` between quit and relaunch sees their changes take
  effect.
- **ID preservation.** Session/tab/pane IDs written verbatim. On restore,
  `SessionStore`'s ID counters advance to `max(id) + 1` per kind, so new IDs
  never collide with restored ones.
- **`lastActivatedAt` persisted.** Drives the running-sessions LRU sort in the
  session manager.
- **URL encoding.** Default `Codable` URL encoding (`absoluteString`).
- **Version at top level.** Optional-field additions are backward-compatible;
  breaking changes bump version; v1 decoder rejects unknown versions.

### Deliberately omitted fields

- `MisttyTab.title` — live OSC-2 title, stale by definition; new process
  rebuilds it.
- `MisttyTab.hasBell`, `windowModeState`, `copyModeState`, `zoomedPane` —
  ephemeral UI state.
- `MisttyPane.processTitle`, `waitAfterCommand`, `useCommandField` — derived,
  ephemeral, or popup-only.
- `MisttySession.popups`, `activePopup` — ephemeral, toggle-on-demand.
- Tab-bar override, sidebar visibility — already in `@AppStorage`.

## Process detection

### libghostty patches

**`0002-expose-shell-pid.patch`** — adds
`ghostty_surface_command_pid(surface) -> pid_t`. Reads the child PID from
termio's subprocess tracking. Returns `-1` before child start or after exit.
~15 lines.

**`0003-expose-pty-slave-fd.patch`** — adds
`ghostty_surface_pty_fd(surface) -> c_int` returning the master fd of the pty
pair. Returns `-1` if unavailable. ~15 lines.

Applied by existing `just patch-ghostty`; `just build-libghostty` depends on
it. Same pattern as `0001-respect-wait-after-command-opt.patch`.

### `Mistty/Support/ForegroundProcess.swift`

```swift
struct ForegroundProcess: Equatable {
  let executable: String  // basename, e.g. "nvim"
  let path: String        // full path, e.g. "/usr/local/bin/nvim"
  let argv: [String]      // incl. argv[0]
  let pid: pid_t
}

enum ForegroundProcessResolver {
  /// Returns nil when the pane has no distinct foreground process beyond the
  /// shell, when detection fails, or when the shell has exited.
  static func current(for pane: MisttyPane) -> ForegroundProcess?
}
```

**Primary path — `tcgetpgrp(pty_fd)` (patch C):**
1. `fd = ghostty_surface_pty_fd(surface)`; if `< 0`, fall through.
2. `pgid = tcgetpgrp(fd)`; if `<= 0`, fall through.
3. `shellPid = ghostty_surface_command_pid(surface)`; if `pgid == shellPid`,
   shell is foreground → return nil (= bare shell; no relaunch).
4. Describe `pgid`: `proc_pidpath(pid,…)` for executable path;
   `sysctl [CTL_KERN, KERN_PROCARGS2, pid]` for argv.

**Fallback path — descendant walk (patch B):**
1. `shellPid = ghostty_surface_command_pid(surface)`; if `< 0`, return nil.
2. BFS via `proc_listpids(PROC_PPID_ONLY, parent, …)` to find the deepest live
   descendant.
3. If no descendants → return nil (bare shell).
4. Describe that pid (same helpers).

Both paths funnel through `describe(pid:) -> ForegroundProcess?` so the
post-pid logic is testable with pid fixtures.

### Config shape & parsing

```toml
[[restore.command]]
match = "nvim"                 # no strategy → replay argv (nvim mytext.txt)

[[restore.command]]
match = "claude"
strategy = "claude --resume"   # explicit strategy replaces argv

[[restore.command]]
match = "ssh"                  # replay argv: ssh user@host

[[restore.command]]
match = "vim"                  # aliases just get their own entry

[[restore.command]]
match = "less"                 # less myfile.log
```

```swift
struct RestoreCommandRule: Sendable, Equatable {
  var match: String       // exact basename match
  var strategy: String?   // nil ⇒ replay argv
}

struct RestoreConfig: Sendable, Equatable {
  var commands: [RestoreCommandRule] = []

  func resolve(_ captured: CapturedProcess) -> String? {
    guard let rule = commands.first(where: { $0.match == captured.executable })
    else { return nil }                           // not allowlisted → bare shell
    if let strategy = rule.strategy, !strategy.isEmpty { return strategy }
    return shellJoined(captured.argv)              // single-quote escape
  }
}
```

Parsed in `MisttyConfig.parse` alongside `[ssh]` / `[copy_mode.hints]`. First
matching rule wins (matches existing `SSHConfig.resolveCommand`).

`shellJoined` single-quote-escapes any element containing metacharacters,
mirroring `MisttySession.wrapPopupCommand`.

### Edge cases

| Situation | Behavior |
|---|---|
| Shell is foreground (idle prompt) | no `captured`; bare shell on restore |
| Foreground is a pipeline (`git log \| less`) | pgid = pipeline leader's pid; leader captured. Pipeline not reconstructed; if leader matches allowlist it gets relaunched solo. Acceptable first-cut. |
| `proc_pidpath` / `KERN_PROCARGS2` fails | treat as no foreground → bare shell; logged via DebugLog |
| Executable path no longer exists at restore (user uninstalled nvim) | allowlist matches on basename; ghostty fails to exec; pane shows error (same as typing a missing command) |
| Pane's shell already exited at save | no `captured`; on restore a fresh shell starts |
| PTY fd patch works but `tcgetpgrp` returns `-1` (no controlling tty) | fall through to fallback path |
| Both patches fail (malformed build, release regression) | resolver returns nil → everything restores as bare shells at CWDs. Structural restore still works. |

## Restore flow & SwiftUI interop

### Launch sequence

```
1. MisttyApp.init()
   - SessionStore() created empty
   - AppDelegate.store = store
   - AppDelegate.observer = StateRestorationObserver(store:)

2. NSApplicationMain
3. applicationWillFinishLaunching

4. [system calls] application(_:didDecodeRestorableState:)
   - decode Data from key "workspace"
   - JSONDecoder → WorkspaceSnapshot (bails if version unknown)
   - store.restore(from: snapshot, config: MisttyConfig.loadedAtLaunch.config)
     → rebuilds sessions/tabs/panes/layouts from snapshot
     → advances id generators: nextID = maxSeenID + 1 (each kind)
     → sets activeSession / activeTab / activePane per saved IDs
     → for each pane: resolves CapturedProcess → command via current
       RestoreConfig
   - Any throw → log via DebugLog; store stays empty

5. applicationDidFinishLaunching
6. SwiftUI WindowGroup spawns its first window
   - @Observable SessionStore already populated → sidebar renders immediately
   - PaneView lazy-inits each MisttyPane.surfaceView → ghostty spawns shells
   - Each pane surface gets:
     * working_directory = pane.directory
       (set to snapshot.currentWorkingDirectory ?? snapshot.directory)
     * command = resolved allowlist strategy (or nil → bare shell)
```

AppKit's `didDecodeRestorableState` fires before SwiftUI creates the window,
so no flash of empty state. Confirmed by the Phase 3 spike below.

### Save trigger

One file, `Mistty/Services/StateRestorationObserver.swift`:

```swift
@MainActor
final class StateRestorationObserver {
  let store: SessionStore
  init(store: SessionStore) { self.store = store; reobserve() }

  private func reobserve() {
    withObservationTracking {
      _ = snapshotKeys()     // reads every field flowing into WorkspaceSnapshot
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        NSApp.invalidateRestorableState()
        self?.reobserve()
      }
    }
  }

  private func snapshotKeys() {
    // Structured read over store.sessions, each session's tabs, each tab's
    // layout + activePane.id, each pane's directory + currentWorkingDirectory.
    // @Observable tracks every access; any mutation re-fires reobserve().
  }
}
```

One observer, one file. No sprinkled `invalidateRestorableState()` calls
through the domain model. AppKit coalesces and serializes at its own cadence.

CWD updates (OSC 7) are noisy. AppKit's coalescing makes the cost negligible;
the alternative (filtering out CWD signals) means quitting right after a `cd`
loses the update. Accept the noise.

### AppDelegate sketch

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var store: SessionStore!
  var observer: StateRestorationObserver!

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
    let snapshot = store.takeSnapshot()
    if let data = try? JSONEncoder().encode(snapshot) {
      coder.encode(data, forKey: "workspace")
    }
  }

  func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
    guard let data = coder.decodeObject(of: NSData.self, forKey: "workspace") as Data?
    else { return }
    do {
      let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
      store.restore(from: snapshot, config: MisttyConfig.loadedAtLaunch.config)
    } catch {
      DebugLog.shared.log("restore", "decode failed: \(error)")
    }
  }
}
```

```swift
@main struct MisttyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @State private var store = SessionStore()
  init() {
    appDelegate.store = store
    appDelegate.observer = StateRestorationObserver(store: store)
  }
  // body unchanged
}
```

### Empty & error cases

| Situation | Behavior |
|---|---|
| No saved state (first launch, Option-Quit, System Setting off) | `didDecodeRestorableState` not called; empty workspace; existing cold-start UI |
| Saved state, unknown schema version | decoder bails; log; empty workspace |
| Saved state references directory that no longer exists | `restore` swaps the missing dir for `homeDirectoryForCurrentUser` via `FileManager.fileExists` check; ghostty spawns in home |
| Saved pane had captured process, user removed allowlist entry | bare shell |
| Saved pane had captured process, user changed strategy | new strategy runs |
| activeSessionID / activeTabID / activePaneID no longer resolves | defensive: first available fills in |

### Interop risk

Unknown: does SwiftUI's `WindowGroup` create its window *before*
`didDecodeRestorableState` fires? Apple's documented order has state
restoration between `willFinishLaunching` and `didFinishLaunching`; SwiftUI
creates scene windows after `didFinishLaunching`, so the order should be safe.

**Phase 3 spike confirms before committing further.** Fallback if the order
races: `WindowGroup { ContentView… }.restorationBehavior(.disabled)` and gate
`ContentView.onAppear` on a `store.didRestore` flag that
`didDecodeRestorableState` sets.

## Phased implementation

**Phase 1 — Snapshot DTO layer + SessionStore round-trip.** Pure scaffolding;
no user-visible change.
- `MisttyShared/Snapshot/*.swift` DTOs.
- `SessionStore.takeSnapshot()`, `SessionStore.restore(from:config:)`.
- `RestoreConfig` parsing + resolution (captured always nil for now).
- Unit tests for DTO round-trip, restore rebuild, config parsing.

**Phase 2 — libghostty patches + foreground process detection.** Snapshot gets
richer; nothing restores it yet.
- `patches/ghostty/0002-…`, `0003-…`.
- Confirm `just patch-ghostty` picks them up; rebuild.
- `ForegroundProcessResolver` with primary + fallback paths.
- Unit tests via injectable seams for `procPidpath` / `tcgetpgrp`.
- Wire `takeSnapshot()` to populate `CapturedProcess`.

**Phase 3 — AppKit state-restoration interop spike.** Diagnostic only.
- Empty `AppDelegate` with `applicationSupportsSecureRestorableState = true`,
  logging-only encode/decode hooks.
- Dev build: confirm `didDecodeRestorableState` fires before SwiftUI creates
  its first window.
- Merged with the rest once the ordering is proven.

**Phase 4 — Full restore wiring.**
- AppDelegate encode/decode fully populated.
- `StateRestorationObserver` installed.
- CWD / directory fallback.
- Allowlist resolution flows pane commands to ghostty.
- End-to-end: 2 sessions × 2 tabs × splits → quit → relaunch → layouts + CWDs
  intact.

**Phase 5 — Debug CLI affordance.**
- `mistty-cli debug state` + IPC op.
- Returns pretty-printed `WorkspaceSnapshot` JSON.

## Testing

- `WorkspaceSnapshotTests` — JSON round-trip, version bump rejection,
  optional-field forward-compat.
- `SessionStoreRestoreTests` — `restore(from:config:)` rebuilds IDs, layouts,
  active markers; advances id generators; handles missing directories.
- `RestoreConfigTests` — rule parsing, argv shell-joining, first-match-wins,
  missing strategy replays argv.
- `ForegroundProcessResolverTests` — injected seams for patch-dependent calls;
  verify fallback order and shell-detect.
- Manual: dev build spike for SwiftUI timing; verify Option-Quit clears;
  verify nvim / claude round-trip.

## Acceptance criteria

1. Quit Mistty with N sessions, each with M tabs, each with K panes in
   non-trivial layouts. Relaunch. All sessions/tabs/panes appear in saved
   order with saved layouts and split ratios.
2. Each restored pane's shell starts in the pane's live CWD (OSC 7 from save
   time), not the session's initial directory.
3. Custom session names and custom tab titles survive the round-trip.
4. Active session, active tab per session, active pane per tab all resolve to
   their saved identities.
5. A pane running `nvim foo.txt` at save, with `[[restore.command]] match =
   "nvim"` configured, restores to `nvim foo.txt` in the same CWD.
6. A pane running `claude`, with `strategy = "claude --resume"`, restores to
   `claude --resume` in the same CWD.
7. A pane running `npm run dev` with no matching allowlist entry restores to a
   bare shell in the same CWD. No error, no relaunch attempt.
8. With `[[restore.command]] match = "ssh"` in config, an SSH pane captured at
   save time as `ssh user@host` is relaunched with that argv — user lands at a
   fresh remote shell. Without an `ssh` allowlist entry, the pane restores as a
   bare local shell (same as any other non-allowlisted program).
9. Hold Option on Quit → next launch is empty (standard macOS behavior).
10. System Settings → "Close windows when quitting an app" = on → next launch
    is empty.
11. `mistty-cli debug state` dumps a valid `WorkspaceSnapshot` as JSON.
12. Force-quit (kill -9) after a structural mutation → next launch has the
    mutation (AppKit's autosave covered it).

## Known follow-ups (v2+)

- Named / user-saved layouts. Additive: `mistty-cli layout save <name>` writes
  a `WorkspaceSnapshot` to `~/.config/mistty/layouts/<name>.json`;
  `layout load <name>` reads and applies. Schema unchanged.
- Pipeline capture — replay `git log | less` as a pipeline.
- `match_regex` / `match_any` allowlist matchers if users ask.
- Window-frame persistence once multi-window is fixed.
- Upstream the shell-PID patch to ghostty.
- Scrollback preservation — needs a libghostty screen-buffer write API.
