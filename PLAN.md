# Mistty

## Idea

I want to build a terminal emulator for macOS built on libghostty. The main differentiating factor for this terminal should be that it uses a heavy session based workflow based on how I use tmux today, but all the tmux features I use are built right into the terminal.

My workflow with tmux looks like this:

- Open the session manager (cmd+j)
- The session manager shows a list:
  - Running sessions
  - Recent directories (via zoxide)
  - SSH hosts (via ssh config)
- I start typing and the list of sessions is filtered with fuzzy finding
- Hitting enter opens that session with all tabs, panes, etc.

Furthermore, it is fully keyboard driven (any function MUST be accessible via keyboard shortcut) and configurable via config file (XDG config compliant, e.g. ~/.config/mistty/config.toml)

## TODO

### State restoration v2+ followups

v1 is shipped (see `## Implemented` below). Outstanding work:

- Named / user-saved layouts (`mistty-cli layout save <name>` / `load <name>`). Additive on top of the v1 snapshot schema.
- Scrollback preservation — needs a libghostty screen-buffer write API that doesn't exist today. Terminal.app-style parity would require a sizable upstream patch.
- Pipeline capture — replay `git log | less` as a pipeline instead of just the leader.
- `match_regex` / `match_any` allowlist matchers if the flat-basename match turns out to be limiting.
- Window frame / position persistence — unlocked once multi-window is fixed and we switch to per-window encoding.
- Popup, copy/window/search mode, zoomed-pane persistence — all ephemeral today; snapshot schema can absorb them without migration if a real need shows up.
- Upstream the shell-PID accessor patch to ghostty.
- **Opt-out mechanism for builtin auto-restore** — `ssh` is in `RestoreConfig.builtinAutoRestore` so SSH sessions relaunch without requiring an allowlist entry. Users with unreachable hosts or one-shot SSH panes have no way to suppress the reconnect attempt short of also suppressing the session's existence. Consider a `strategy = false` or similar sentinel, or a per-executable `auto_restore = false` flag in the rule.

### Keyboard shortcut configuration

- Many of the keyboard shortcuts are hardcoded right now, make them configurable
- Session reordering so ctrl-1..9 is actually useful (shortcut + drag-and-drop in sidebar)

### Preference Pane

- We have a non-standard preference pane right now. Make a pref pane like Safari, Mail, etc., that looks like a standard macOS preference pane
- Shortcuts have to be put in manually, record the shortcuts instead

### Non-standard pane

- mistty-cli should be able to open a markdown file with full rendering support. This overlays a markdown view over the terminal (make sure to respect light/dark mode when rendering!) `mistty-cli open --{markdown,md} <file>`
  - supports rendering mermaid diagrams & images
  - Obsidian markdown support
  - hitting "e" opens the file in $EDITOR for editing, closing the file goes back to the markdown view and shows the updated render
  - Excalidraw rendering support?
- Same with an embedded webview, e.g. open localhost:3000 in a pane that is a web view for rendering, open docs or html files, ...

### Misc & Bugs

Larger:

- OSC777/OSC9/OSC99 notifications support
- Zen mode (similar to zoomed - except that it pulls out the pane similar to a popup, full height with default 120 character width (configurable), background is dimmed)

### Multi-window v2+ followups

Once v1 ships:

- Per-NSWindow encoding via `NSWindow.encodeRestorableState(_:)` (replaces the single app-level snapshot blob). Unlocks per-window frame/position persistence — already noted under "State restoration v2+ followups" but cleaner once each window is a first-class persistence unit.
- Switch terminal windows from SwiftUI `WindowGroup` to AppKit `NSWindowController`. Cleaner multi-window correctness (window-creation timing, restoration coordination, menu integration) at the cost of a chunkier rewrite. The `WindowsStore` / `WindowState` data model from v1 carries over unchanged.
- Cross-window session/tab/pane moves (Arc-style drag/drop). Requires NSView reparenting coordination for `TerminalSurfaceView`.
- Window menu listing all open windows for jump-to-window navigation.
- Per-window custom names/titles.

## Future

- OSC for state restoration? TUI communicates with term how to get it to resume from where it left. Could be something as simple as `$PROG file.txt` or `nvim -U session.vim` or something more complex.

## Implemented

### Multi-window v1

Spec: `docs/superpowers/specs/2026-04-27-multi-window-v1-design.md`. Plan: `docs/superpowers/plans/2026-04-27-multi-window-v1.md`.

- Each terminal window owns its own sessions/tabs/panes/active markers; opening a new window no longer steals panes from existing windows. `WindowsStore` (global registry: ID counters, lookups, NSWindow tracking) + `WindowState` (per-window sessions/active session) replace the prior single `SessionStore`. SwiftUI `WindowGroup(id: "terminal")` mounts `WindowRootView`; each window claims a `WindowState` from `pendingRestoreStates` (FIFO during restore) or creates a fresh empty one (Cmd+N)
- `WorkspaceSnapshot` v2 with `windows: [WindowSnapshot]`. v1 payloads migrate transparently into a single window so existing users don't lose state. Custom `init(from:)` handles v1 → v2 migration; the public `init(version:windows:activeWindowID:)` is naive (only the decoder sets `unsupportedVersion`)
- Per-window scoping enforced via `WindowsStore.isActiveTerminalWindow(state:)`: every Mistty notification handler in `ContentView` and every `NSEvent.addLocalMonitorForEvents` monitor guards on this so only the focused window's `ContentView` acts. Pane-targeted ghostty notifications stay unguarded — they filter via `windowsStore.pane(byId:)`. Dock badge sums bells across `windowsStore.windows.flatMap(\.sessions).flatMap(\.tabs)` (global)
- Closing the last window keeps the app running (`applicationShouldTerminateAfterLastWindowClosed → false`). Closed windows held in an in-memory `recentlyClosed` stack capped at 10; new menu item **Reopen Closed Window** (Cmd+Shift+T) re-spawns the most recent via the same `pendingRestoreStates` plumbing
- IPC: read endpoints (`session list`, `tab list`, `pane list`, `popup list`) flatten across all windows with a new `window: Int` field on each response. Mutating ops by global id (no `--window` needed). `session create` resolves `--window <id>` → focused terminal window → error "no focused window; pass --window <id> or focus a terminal window first". `window create` (previously "Not supported") now reserves an id synchronously, queues an empty `WindowState` onto `pendingRestoreStates`, and fires `openWindowAction` to spawn the SwiftUI window
- `WindowRootView.onDisappear` retires the `WindowState` and snapshots into `recentlyClosed` only when the NSWindow actually closed (`isVisible == false` on next runloop tick) — minimize/spaces transitions don't trigger close. `closeWindow` is idempotent (`windows.contains(where:)` guard) so the IPC `closeWindow` path and the `onDisappear` sweep can both fire safely
- `drainPendingRestores()` uses a sized `for` loop over the queue snapshot, NOT `while !pendingRestoreStates.isEmpty` — the queue drains async (each `openWindow(id:)` schedules a SwiftUI mount whose `onAppear` removes one entry in a later runloop tick), so the while-form would hang the main thread on multi-window cold restore
- `DebugLog` breadcrumbs on the `cmdw` and `window` channels are preserved (ported from `SessionStore` to `WindowsStore` so the load-bearing diagnostic logs from past Cmd-W debugging survive the type split)

### Session workflow

- Session manager (cmd+j) with fuzzy find
  - FuzzyMatcher with two-pass greedy algorithm (fzf-style) + Damerau-Levenshtein typo tolerance
  - Multi-token AND matching: space-separated query tokens all must match
  - Subsequence matching across session name, directory path, and SSH hostname
  - Typo tolerance (query 4-6 chars: 1 edit, 7+: 2 edits) with 0.3x score penalty
  - Match quality as primary sort key, frecency as tiebreaker
  - SSH boost (1.5x) when query starts with "ssh"
  - Match highlighting: matched characters shown in accent color via HighlightedText view
  - Tab/Right Arrow completion: fills selected item's path into search field
  - "New" option at top of results when query is non-empty (not default-selected unless only item)
    - Plain text mode: creates session with query as name in active pane's CWD (Cmd for home)
    - Path-like mode: creates session in directory, offers to create directory if parent exists
    - SSH mode: creates SSH session when query starts with "ssh hostname"
- Running sessions list
- Recent directories via zoxide (ZoxideService)
- SSH hosts from ~/.ssh/config (SSHConfigService)
- Frecency-based sorting (FrecencyService with time-weighted scoring)
- Current session hidden in session manager

### Standard terminal functions

- New tab (cmd+t)
- Rename tab (cmd+shift+r, or double-click tab title for inline edit)
- New split pane horizontal (cmd+d) and vertical (cmd+shift+d)

### Sidebar

- Shows all open sessions with tabs nested in collapsible disclosure groups
- Collapsible sidebar (cmd+s) with resizable drag handle
- Bell activity indicator (orange dot) on tabs with background bell
- Highlights current session and current tab

### Window mode (cmd+x)

- Toast popup with orange border and help overlay
- Grow/shrink panes: `cmd+arrows` = 5 rows/cols, `cmd+shift+arrows` = 1 row/col (new helper `PaneLayout.resizeSplit(containing:cells:along:cellSize:tabSize:)` converts cells → ratio against the target split's actual container size so nested splits don't jump)
- Swap panes in direction (arrow keys)
- Break pane to new tab (b)
- Merge/join pane to existing tab (m, then number key to pick target)
- Rotate pane direction (r)
- Press number keys to switch standard layouts
  1. even-horizontal
  2. even-vertical
  3. main-horizontal
  4. main-vertical
  5. tiled

### Copy mode

- Enter/exit copy mode (cmd+shift+c)
- Toast shows keyboard hint badges per submode (mirrors window mode style)
- Vim navigation: h/j/k/l, w/W/e/E/b/B, ge/gE with vim-exact word boundaries, 0/$ line start/end, g/G top/bottom
- Count prefix for motions (10j, 3w, 5G)
- f/F/t/T find-character on current line, ;/, repeat/reverse
- Visual modes: v (character), V (line), Ctrl-v (block) with proper selection highlighting
- Yank (y) selection to clipboard via ghostty_surface_read_text
- Search: / forward, ? reverse, n/N next/prev, match count indicator, all-match highlighting, full scrollback coverage
- Scrollback navigation: Ctrl-D/U half page, Ctrl-F/B full page, word motions wrap into scrollback
- Help overlay (g?)

### Copy mode improvements

Broken into three phases. Phase 1 has a full spec at `docs/superpowers/specs/2026-03-18-copy-mode-phase1-design.md`.

#### Phase 1: Motion & selection (spec complete)

- Refactor CopyModeState to action-based state machine with `handleKey` returning `[CopyModeAction]`
- Visual line mode (V), visual block mode (Ctrl-v)
- Tmux-style escape: esc from visual -> copy mode, esc from copy mode -> exit
- Number prefix for movement commands (10j, 3w, 5G, etc.)
- Proper word motions: w/W/e/E/b/B/ge/gE with vim-exact word/WORD definitions
- f/F/t/T find-character on current line, ; and , for repeat/reverse
- Toggle-able help overlay (g?) showing keybindings

#### Phase 2: Scrollback & search

- Navigate through scrollback buffer (not just viewport)
- Search hit highlighting (all matches visible, not just current)
- ? support (reverse search) — `?` key reassigned from help overlay to reverse search
- Cross-line word motion wrapping into scrollback
- Handle Ctrl-D/U and other paging shortcuts

#### Phase 4: per-pane state, viewport jumps, scroll-drift fix

Spec: `docs/superpowers/specs/2026-04-25-copy-mode-yank-and-config-reload-design.md`. Plan: `docs/superpowers/plans/2026-04-25-copy-mode-yank-and-config-reload.md`.

- Per-pane copy-mode state: `CopyModeState` lives on `MisttyPane` (was on `MisttyTab`). Each pane keeps its own scroll position / cursor / selection across focus switches. The overlay only renders on the focused pane; other panes with stored state stay scrolled to their saved position with no chrome until refocused. `MisttyTab.copyModeState` is now a passthrough getter/setter onto the active pane so existing call sites keep working
- Ctrl-h/j/k/l switches focus while copy mode stays active on the source pane. The copy-mode keyDown monitor passes those four keys through to `ctrlNavMonitor` (other Ctrl-* keys — d/u/f/b paging, Ctrl-v block mode — keep being handled by copy mode); resuming copy mode is just `Ctrl-h` back. Monitor moved into ContentView's `.onAppear` set so it stays installed for the view's lifetime; enter/exit no longer install or remove it
- `gg` / `G` now scroll to the top of scrollback / live edge respectively (was: cursor-only within the visible viewport). New `H` / `M` / `L` jump cursor to viewport top / middle / last row without scrolling, with count support (3H = third from top, 3L = third from bottom). New `CopyModeAction.scrollToTop` / `.scrollToBottom` — `ContentView` translates them into `scrollViewport` calls using the live scrollbar offset/total
- Scroll-drift fix: `scrollViewport` adjusts the anchor by the *actual* offset change post-clamp, not the requested delta. Phantom scrolls past the top of scrollback or the live edge no longer drift the anchor away from its true screen position (combined with the libghostty pin-clamp patch in `### Bug fixes`, this is what made cross-viewport yank produce correct content — see the entry there for the full root cause)

### Copy mode — yank hints (Phase 3)

- `y` (no selection) enters hint mode (copy action)
- `o` enters hint mode (open action — macOS `open` / NSWorkspace)
- `Y` enters line hint mode (labels at col 0 of each non-empty visible line)
- `cmd+shift+y` enters copy + hint mode in one step (esc then exits copy mode entirely)
- Detectors: URLs, emails, UUIDs, paths (absolute + relative), git hashes, IPv4/IPv6, env vars, numbers; quoted strings and code spans are transparent containers (inner matches still hinted)
- Longest peer match wins; priority tiebreak (url > email > uuid > path > hash > ipv4 > ipv6 > envVar > number); containers emit alongside inner peers
- tmux-thumbs label generation (single-char, expanding to 2-char); bottom-to-top left-to-right order
- Uppercase typed label swaps copy/open action (configurable via `uppercase_action`)
- Tab cycles filter by kind (url, email, uuid, path, hash, ipv4, ipv6, envVar, number, quoted, codeSpan, all), skipping kinds with no matches
- Re-scans on keyboard paging (Ctrl-U/D/F/B) and mousewheel scroll
- Config: `[copy_mode.hints]` alphabet (default `asdfghjkl`) and uppercase_action (default `open`)

### CLI control (mistty-cli via XPC/Mach service)

- Session CRUD: create, list, get, close (with --name, --directory, --exec)
- Tab CRUD: create, list, get, close, rename
- Pane CRUD: create, list, get, close, focus, resize, send-keys, run-command, get-text, active
- Window CRUD: create, list, get, close, focus
- Popup commands: open, close, toggle, list
- JSON and human-readable output formats

### Popup support

- Configurable popup definitions in config.toml (name, command, shortcut, width, height, close_on_exit)
- Popup overlay UI with semi-transparent backdrop, header bar, close button
- Toggle via configurable keyboard shortcuts
- CLI popup commands (open/close/toggle/list)
- Popup inherits current pane's working directory
- Per-popup `cwd` config (`session` / `active_pane` / `home`, default `active_pane`) exposed as a segmented picker in Settings; `active_pane` now reads the live OSC 7 CWD, falling back to initial pane dir, then session dir

### Navigation

- Ctrl-h/j/k/l between panes with smart neovim pass-through
- Cmd-1 through cmd-9 to focus tab by index
- Ctrl-1 through ctrl-9 to focus session by index
- Cmd-]/cmd-[ for next/prev tab (circular), also cmd-down/up as alternates
- Cmd-shift-up/down to cycle between sessions (circular), also cmd-shift-]/[ as alternates
- Cmd-opt-up/down to move the active session up/down in the sidebar, also cmd-opt-[/] as alternates

### SSH integration

- SSH auto-connect for SSH session types
- Configurable SSH command with per-host overrides in config
- Option modifier bypasses SSH auto-connect on new panes

### Config & preferences

- Config file parsing from ~/.config/mistty/config.toml
- Preference pane (cmd+,) for font size, cursor style, scrollback, sidebar visibility
- Popup definition configuration
- `zoxide_path` top-level key to explicitly point at the zoxide binary (skips the candidate probe + `bash -lc` fallback; useful for exotic installs or to avoid spawning bash on every cold start)
- `debug_logging` opt-in: writes diagnostic traces to `~/Library/Logs/Mistty/mistty-debug.log` via a `DebugLog` helper. Toggle + log path + Reveal button surfaced in Settings → Debug. Used today to instrument the Cmd-W misroute path (register/unregister of tracked windows, `isTerminalWindowKey` returning false, menu vs. monitor decision)

### Repo / agent hygiene

- `just setup-worktree` recipe: initializes `vendor/ghostty` submodule and symlinks the prebuilt `GhosttyKit.xcframework` from the main checkout so `git worktree add` dirs build immediately
- `just run [<worktree>]` wraps install + open, optionally from a `.worktrees/<name>` directory for quick manual verification of a branch
- `AGENTS.md` at repo root: agent-facing doc covering build/test commands, worktree flow, and project-specific conventions
- Atomic install (`just install` / `install-release`): the previous flow did `osascript quit + rm + cp` synchronously, which crashed Mistty when invoked from a pane inside the very app being upgraded — the AppleEvent quit killed the script's host shell mid-cp, leaving the bundle rm'd while the OS was still tearing down its binary. New flow stages the new bundle at `${dst}.new` while the live app is still mounted, then forks a detached helper (subshell + `nohup` + redirected stdio) that polls until the running binary exits, atomically `rm` + `mv`s the staging bundle into place, and `open`s it. Both install recipes route through a shared `_atomic-install` private recipe
- Distinct dev / release bundle IDs: `just bundle` runs `plutil -replace CFBundleIdentifier -string com.mistty.app.dev` on the dev `.app`'s `Info.plist` after copying it from the shared template. Release keeps `com.mistty.app`. Side-effects: AppKit's saved-state directory (`~/Library/Saved Application State/<bundleID>.savedState/`) and `NSUserDefaults` storage are now per-build, so running dev no longer clobbers release's restored state on quit. Cosmetics (Dock icon variant, AppleScript-by-path targeting, IPC socket suffix) were already split — only the bundle ID was shared

### Native macOS UI

- SwiftUI + AppKit hybrid (terminal surface is NSView, UI is SwiftUI)
- Tab bar with horizontal scrolling, close buttons, new tab button
- Process title display via ghostty notifications

### Chrome polish (v0.3)

- Minimal subtle-pill tab bar (28pt). Configurable visibility via `ui.tab_bar_mode`: `always`, `never`, `when_sidebar_hidden`, `when_sidebar_hidden_and_multiple_tabs`, `when_multiple_tabs` (default)
- Tab bar runtime toggle (cmd+shift+b) layers on top of the configured mode via `TabBarVisibilityOverride` (auto/hidden/visible) in AppStorage
- Title bar style configurable via `ui.title_bar_style`: `always`, `hidden_with_lights` (default, traffic lights float over content), `hidden_no_lights` (no chrome at all — close via cmd+w)
- Sidebar slide-in/out animation (180ms), process icons per session/tab row, CWD-for-session + process-title-for-tab label format
- Session manager rows use SFSymbols per row type (terminal, folder, ssh, plus.circle)
- Symbols Nerd Font Mono v3.2.1 bundled as SPM resource and registered at launch for ProcessIcon glyphs
- Ghostty content padding exposed as `ui.content_padding_x`, `ui.content_padding_y` (int or [start, end]), `ui.content_padding_balance`. Values pass through to ghostty via a temp config file loaded after the user's `~/.config/mistty/ghostty.conf`
- Pane split border configurable via `ui.pane_border_color` (hex `#rrggbb` / `#rrggbbaa`, falls back to `NSColor.separatorColor`) and `ui.pane_border_width` (points, default 1)
- Annotated sample config at `docs/config-example.toml` covers every option

### Ghostty config passthrough

- `[ghostty]` table in `config.toml` forwards arbitrary ghostty keys (kebab-case) verbatim to libghostty via a temp file loaded after `~/.config/mistty/ghostty.conf`
- Denylist in `GhosttyPassthroughConfig.deniedKeys` drops keys that would conflict with Mistty's own chrome / window / tab / split / keybind / lifecycle management (window-decoration, macos-titlebar-style, keybind, command, quick-terminal-\*, split-divider-color, auto-update, …)
- TOML scalars → one line; TOML arrays → one line per element (so repeatable keys like font-family / palette work)
- `theme` is emitted before other passthrough keys so user overrides win over the theme's defaults; remaining keys follow alphabetical order
- Top-level `font_size`, `font_family`, `cursor_style` in `config.toml` now flow through to ghostty when they differ from Mistty defaults (previously dead settings)
- `[ui].content_padding_*` and `[ui].pane_border_*` still take precedence over anything under `[ghostty]`

### State restoration (v1)

Spec: `docs/superpowers/specs/2026-04-22-state-restoration-design.md`; plan: `docs/superpowers/plans/2026-04-22-state-restoration.md`.

- Auto-save workspace on quit (and on AppKit's periodic checkpoints) via `NSApplicationDelegate`'s `application(_:willEncodeRestorableState:)`; auto-restore on launch via `didDecodeRestorableState` before the SwiftUI window materializes (verified via spike). `applicationSupportsSecureRestorableState → true`.
- Structure preserved: sessions/tabs/panes/layouts/CWDs, split ratios, custom session/tab names, `lastActivatedAt`, active session/tab/pane markers. Pane IDs preserved verbatim across restore; ID counters advance past max seen ID.
- Allowlist-driven process relaunch via `[[restore.command]]` in `config.toml`. `match` on basename; optional `strategy` string replaces argv, absent/empty replays captured argv POSIX-shell-quoted. Examples in `docs/config-example.toml` cover nvim/vim/claude/ssh/less/htop.
- Foreground process detection via `tcgetpgrp(pty_fd)` on the pane's PTY (primary) with a descendants-of-shell-PID walk as fallback. Both paths feed `proc_pidpath` + `KERN_PROCARGS2 sysctl` to read the executable and full argv. Two libghostty patches add `ghostty_surface_command_pid` and `ghostty_surface_pty_fd` exports.
- `StateRestorationObserver` uses `withObservationTracking` to call `NSApp.invalidateRestorableState()` on any snapshot-relevant mutation (session/tab/pane add/remove, reorder, rename, activePane change, CWD/OSC-7 change, split ratio change). AppKit coalesces and serializes.
- `WorkspaceSnapshot` schema versioned (`version = 1`); unknown versions bail to empty state with a log line. DTOs live in `MisttyShared/Snapshot/`.
- Missing-directory fallback: pane CWDs that no longer exist at restore time (user deleted the dir) are replaced with `$HOME` so the shell doesn't die immediately.
- Hold Option on Quit clears saved state; System Settings → "Close windows when quitting an app" is honored natively (AppKit handles both).
- `mistty-cli debug state` dumps the current `WorkspaceSnapshot` as pretty-printed JSON via a new `getStateSnapshot` IPC RPC.

### Config reload

Spec: `docs/superpowers/specs/2026-04-25-copy-mode-yank-and-config-reload-design.md`. Plan: `docs/superpowers/plans/2026-04-25-copy-mode-yank-and-config-reload.md`.

- `MisttyConfig.current` is a mutable `static var` swapped by `MisttyConfig.reload(from:)` (default `~/.config/mistty/config.toml`). On parse error throws and leaves `current` unchanged (also stashing the error in `lastParseError` so callers can surface it); on success posts `Notification.Name.misttyConfigDidReload` and returns the new value. Replaces the previous one-shot `loadedAtLaunch` static let
- Triggers all funnel into `MisttyConfig.reload()`: `View → Reload Config` menu item (no default keyboard shortcut), `mistty-cli config reload` (new IPC RPC + ArgumentParser subcommand, with `ensureReachable()` parity), and `SettingsView.save()` which now debounces 400ms via a `@State pendingSave: Task<Void, Never>?` so per-keystroke `.onChange` save calls coalesce into a single reload
- `GhosttyAppManager.reloadConfig()` builds a fresh `ghostty_config_t` (load `~/.config/mistty/ghostty.conf`, layer the resolved Mistty-managed lines via a temp file, finalize) and pushes it through `ghostty_app_update_config(app, newCfg)` — ghostty propagates the new config to every surface, so font / scrollback / palette / padding / theme update live with no surface recreation. Old configs are retired into a list and freed at app shutdown to dodge in-flight surface message races. `buildGhosttyConfig(from:)` is the shared helper that init also uses, so the bootstrap path and the reload path can't drift
- Reactive consumers: `MisttyApp` switches its config from `let` to `@State` and refreshes on `.misttyConfigDidReload`, also re-applying `applyTitleBarStyleToWindows()` and `DebugLog.shared.configure(enabled:)` so window chrome and debug-logging follow live edits. `SettingsView` shows parse errors on an inline red banner (replacing the silent `try?` swallow) and listens for external reloads to refresh its `@State`. `ZoxideService` clears its `CachedExecutable` on reload so a `zoxide_path` change takes effect on the next session-manager open
- Out of scope (deferred): filesystem watcher for auto-reload, per-key "needs restart" diff/warning UI, reloading the per-surface initial command (commands are spawned at creation; not a reload concern)

### Bug fixes

- Cmd-W sometimes closed the whole terminal window instead of the pane: the `onAppear` registration fell back to `NSApplication.shared.keyWindow` behind a `DispatchQueue.main.async`, so during AppKit state restoration (windows exist before they're key) or when multiple terminal windows coexisted, the host window wasn't tracked. The menu-item fallback then saw `isTerminalWindowKey() == false` and called `NSApp.keyWindow?.performClose(nil)` on the actual terminal window. New `WindowAccessor` (`viewDidMoveToWindow`-backed NSViewRepresentable) binds registration to the _real_ host window, synchronously, with no race
- Window Mode shortcut "disappears" from the menu bar: SwiftUI disables the `Cmd+X` menu shortcut whenever a text responder (sidebar rename TextField, Settings search, any focused `NSText`) enables the system Cut command, so the shortcut silently becomes Cut and the "⌘X" indicator moves to Edit → Cut. New app-level `windowModeShortcutMonitor` (mirrors the `Cmd+W` monitor pattern) intercepts `Cmd+X` before SwiftUI's menu routing whenever the terminal window is key, then passes through only when the first responder is `NSText` so text fields still cut normally
- Popup rounded-corner clipping: `.clipShape(RoundedRectangle)` on a `VStack` containing the ghostty-backed `TerminalSurfaceView` (CAMetalLayer) didn't propagate the mask through the Metal layer tree, so the corner areas showed the terminal's opaque background instead of transparency. `.compositingGroup()` before `.clipShape` forces SwiftUI to render the subtree into an offscreen bitmap first so the clip applies to the composed result
- Popup `close_on_exit = false` showed stale "press any key to close" on reactivation: the surface-close callback only set `isVisible = false`, leaving the dead pane cached in `session.popups`. The next toggle reused it. Now we always `session.closePopup(popup)` on surface close — the `close_on_exit` flag only decides whether ghostty lingers on "press any key", not whether Mistty keeps the dead pane around
- Window Mode focus-without-swap: `hjkl` now focuses the adjacent pane in window mode (arrow keys still swap). Lets the user chain focus → swap → resize without leaving the mode. Hints row updated
- Rename sessions: double-click a session row in the sidebar, or hit `Cmd+Opt+R` from the menu to enter inline edit. Mirrors the tab-rename pattern (extracted `beginEditing`/`finishEditing`, focus handed back to the active pane on commit)
- Bells show on the Dock icon: `updateDockBadge()` sets `NSApp.dockTile.badgeLabel` to the count of background tabs with `hasBell`; fires on bell ring, tab-switch (which clears the ringing tab's bell), and tab/pane close (so closing a bell-tab drops the badge)
- Drag to resize panes: thin split borders now host a `SplitDivider` whose visible line keeps its `borderWidth` layout footprint (HStack/VStack lays out panes unchanged) while an `.overlay` with a 6pt frame extends the hit area over the adjacent panes' edges — mirrors ghostty's own `SplitView.Divider` (1pt visible + 6pt invisible) but uses SwiftUI's overlay-beyond-parent trick instead of absolute `.position()`. Captures a `DragGesture` and reports incremental ratio deltas to `PaneLayout.resizeSplit(between:and:delta:)` — a new API that walks to the exact split whose divider was grabbed (keyboard-resize's `containing:along:` variant grabs the outermost matching-direction ancestor, which is wrong for drag). Cursor flips to the standard resize cursor on hover
- Zoomed-pane indicator: SF Symbol next to the tab title in both sidebar and tab bar when `tab.zoomedPane != nil`
- Search ranking: running sessions get a 1.5× score boost so an open session outranks a comparable directory/SSH match; subtitle (path/hostname) matches penalized 0.6× so a clean displayName hit beats a scattered match across a long path
- Session manager sort: running sessions pinned to the top in LRU order via a new `MisttySession.lastActivatedAt` updated by `SessionStore.activeSession.didSet`
- Cmd-W routing: both the SwiftUI menu Button and the global `NSEvent` keyDown monitor now check `store.trackedWindows` before posting the close-pane notification, so Cmd-W closes the focused Settings window instead of leaking through to the terminal behind it
- CLI popup "write failed": `IPCClient` now opens a fresh socket per call (the listener is one-shot), unblocking commands that issue multiple RPCs (e.g. `popup open` calling `listSessions` then `openPopup`)
- Tab-bar override: the Cmd+Shift+B shortcut's override is now ephemeral per-window `@State` (was `@AppStorage`, which pinned it forever). Two presses cycles back to `.auto`, and the override auto-resolves whenever the configured `tab_bar_mode` rule would produce the same visibility (driven by `.onChange` on sidebar visibility and active tab count). See `docs/superpowers/specs/2026-04-19-tab-bar-override-design.md`
- Focus sync across CLI, nav, and splits: `MisttyTab.focusPane(_:)` + `MisttyPane.focusKeyboardInput()` helpers unify the "write activePane + grab first-responder" dance. `IPCService.focusPane`/`focusPaneByDirection` now call the helper (previously moved only the focus ring, not keyboard input). `TerminalSurfaceView.viewDidMoveToWindow` is gated on an `isActive` flag plumbed from SwiftUI so re-mounting a multi-pane session no longer hands first-responder to whichever pane happens to be hosted last. `splitActivePane` focuses the newly-created pane directly (was `layout.leaves.last`, which misfired under nested splits)
- 2x2 ctrl-h/j/k/l navigation: `PaneLayout.adjacentPane` rewritten to use unit-rect geometry. Previously the tree-walking algorithm picked `firstLeaf`/`lastLeaf` of the sibling subtree without regard for the source pane's orthogonal position — from top-right it would jump to bottom-left
- Dark/light mode switching: `TerminalSurfaceView.viewDidChangeEffectiveAppearance` now calls `ghostty_surface_set_color_scheme` (the app-level scheme update alone doesn't push down to existing surfaces' conditional state, so only brand-new panes picked up the right theme previously)
- zoxide discovery on GUI launch: `ZoxideService` resolves the absolute path once per process via a candidate list (Homebrew ARM/Intel, nix-darwin, home-manager, nix single-user, `~/.cargo/bin`, `~/.local/bin`) with a `bash -lc 'command -v zoxide'` fallback and a new `zoxide_path` config override. Fixes the session manager showing only SSH hosts when Mistty is launched from Dock/Finder (minimal PATH) instead of `open Mistty.app` from a terminal
- Tab title sanitation: `TerminalTitle.sanitized` drops OSC 2 payloads whose first whitespace-delimited token is `exit` (shell `preexec` hooks send the literal command line just before the shell dies, leaving `"exit"` / `"exit $PATH"` pinned on the tab). Stale tab titles are cleared on active-pane close — resync to the new active pane's `processTitle`, or back to the default
- Window-mode Cmd+X after session-manager dismiss: Cmd+J's search field was leaking first-responder on Escape, letting Edit > Cut (standard Cmd+X) shadow View > Window Mode. `showingSessionManager` onChange now calls `returnFocusToActivePane` on dismissal
- Cmd+V paste: `readClipboardCallback` / `confirmReadClipboardCallback` were TODO stubs — they read NSPasteboard but never called `ghostty_surface_complete_clipboard_request`, so libghostty silently dropped every paste. Wired through; unsafe-content callback auto-confirms (matching ghostty's default) until a real NSAlert UI is added
- Tab rename from sidebar / hidden tab bar: `TabBarItem` was the sole host of the inline-rename `TextField` and the only observer of `.misttyRenameTab`. Extracted `SidebarTabRow` with its own inline editor, double-click affordance, and notification listener. The sidebar's listener is gated on tab-bar visibility so only one editor activates at a time
- Active session indicator: leading thin accent bar on the active session row in the sidebar, matching the active-tab pattern (bar only, no tinted background since the bold label + accent-tinted process icon already distinguish the row)
- Concurrency warnings: the sole remaining `@Sendable` closure block in `GhosttyAppManager.init` (scheduled config-parse-error NSAlert) switched to `Task { @MainActor in for await _ in NotificationCenter.default.notifications(named:) }`, eliminating all 33 build warnings without any cross-file ripple
- Pane close focus: `MisttyTab.closePane` now calls `focusKeyboardInput()` on the surviving pane after moving `activePane`. Previously the focus ring followed the switch but first-responder stayed on the destroyed surface, so keystrokes vanished until the user clicked. Mirrors the existing `focusPane(_:)` pattern
- Display-scale propagation: `TerminalSurfaceView.viewDidChangeBackingProperties` re-pushes size-in-pixels + content scale to libghostty so plugging/unplugging monitors (external @1x ↔ internal @2x) no longer leaves a surface rendering at the wrong density. `setFrameSize` only fires on point-size changes, which doesn't happen on a pure scale swap — this mirrors the `viewDidChangeEffectiveAppearance` path for dark/light
- Split pane CWD: `splitActivePane` now inherits the focused pane's live working directory (via OSC 7 / `GHOSTTY_ACTION_PWD`) instead of reusing the tab's initial directory. Wires the previously-ignored PWD action through a new `.ghosttyPwd` notification to update `MisttyPane.currentWorkingDirectory`
- Copy mode Enter: Return posts `.exitCopyMode` from any submode except search, which keeps its own Return binding for confirming the query. If a selection is active the existing yank-on-exit path runs, so Enter doubles as "confirm and copy" à la tmux/vim
- Popup command reliability: popups now run their command through `cfg.command` (exec'd via `/bin/sh -c`, tmux-style) instead of typing `exec CMD\n` into a login shell, eliminating the race where a slow `.zshrc` could swallow the input and drop the user at a bare prompt. Requires a local libghostty patch (`patches/ghostty/0001-respect-wait-after-command-opt.patch`) that removes ghostty's unconditional `wait-after-command = true` override — without it, all command panes would require a keypress to close. `just patch-ghostty` applies it, and `just build-libghostty` now depends on it
- Scroll speed: `TerminalSurfaceView.scrollWheel` was passing `0` for the scroll-mods bitmask, so libghostty couldn't tell a trackpad pixel delta from a wheel tick and treated every event as discrete ticks (pixel delta → "this many rows"). Now packs `hasPreciseScrollingDeltas` + `momentumPhase` into the mods (matching ghostty's own AppKit surface) and applies a configurable `scroll_multiplier` (default 2.0, precision-only) that replaces ghostty's hard-coded 2× trackpad feel. Non-precision wheel speed stays on the ghostty discrete path — tune via `[ghostty] mouse-scroll-multiplier` if needed
- Mode chrome colors: window mode keeps orange (tmux-prefix feel + ZOOMED badge + pane border), copy/visual/search use blue, hint/yank picker uses purple. `CopySubMode.chromeColor` is the single source of truth; `CopyModeHints` toast, `CopyModeHelpOverlay` border, and `CopyModeHintOverlay` label pills pull from it. Hint-pill text flipped to white for contrast against the purple fill
- Window mode stuck after session/tab switch: window mode's global keyDown monitor is installed once and reads `store.activeSession?.activeTab`, so pressing `esc` on _any other tab_ removed the monitor while the original tab's `windowModeState` still read `.normal` — toast kept showing, arrows/esc did nothing, only `cmd-x` could toggle out. Fixed by adding a `previousActiveTab` tracker: whenever the active tab id changes, clear window mode on the tab we're leaving and drop the monitor if the new active tab isn't in window mode. Matches tmux-prefix ephemeral semantics — switching away cancels the mode cleanly
- Window mode stay-vs-exit audit: zoom (z) and break-to-tab (b) exit (both commit a terminal state change — zoom is a view state, break moves the pane away). Resize (cmd+arrow), swap (arrow), rotate (r), and standard layouts (1–5) all _stay_ in window mode since users typically chain them with follow-up adjustments. Layouts used to exit but have been changed to match — applying `.tiled` then nudging one pane with cmd+arrow now works without a second cmd-x
- Dev/release CLI socket split: both builds bound to `~/Library/Application Support/Mistty/mistty.sock` and `unlink`'d it on startup, so launching one app killed the other's CLI. Fix is two-part: (1) `MisttyIPC.serverSocketPath` walks up the executable path to the enclosing `.app` and suffixes `-dev` when inside `Mistty-dev.app`, so release and dev bind distinct sockets; (2) `TerminalSurfaceView` sets `MISTTY_SOCKET=<server path>` via ghostty's `env_vars` on every spawned shell, and `MisttyIPC.socketPath` (CLI-side) prefers that env var. That way a single `mistty-cli` on `$PATH` always talks back to the specific instance whose pane invoked it, no matter which app was installed last. The listener stays on `serverSocketPath` explicitly so `MISTTY_SOCKET` leaked in from an external shell can't make the dev app bind the release socket
- Multi-screen copy-mode yank (libghostty patch + Mistty fix): two stacked bugs that both showed up only once a selection extended into scrollback. (a) `Selection.pin` in `vendor/ghostty/src/apprt/embedded.zig` clamped y to `screen.pages.rows -| 1` (viewport height) regardless of point tag, so any `GHOSTTY_POINT_SCREEN` selection that addressed scrollback collapsed both endpoints to the same row near the top of the visible viewport — `read_text` came back with one row instead of the requested range. New `patches/ghostty/0004-screen-tag-pin-clamp.patch` makes the y-clamp tag-aware (`screen.pages.total_rows` for `.screen`/`.history`, `screen.pages.rows` for `.active`/`.viewport`). (b) Mistty-side, the `.visual` (character-wise) yank case in `ContentView.swift` skipped the lexicographic min/max that `.visualLine` and `.visualBlock` already did, so reverse selections (cursor before anchor) sent ghostty inverted `top_left`/`bottom_right`. New `CopyModeYank.normalize(anchor:cursor:)` helper plus 4 unit tests. Together with the scroll-drift fix in copy-mode Phase 4, cross-viewport yank now produces the exact intended range with no off-by-one drift
