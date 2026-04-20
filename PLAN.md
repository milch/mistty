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

### Window mode

- s to save layout for this session / r to restore layout

### Save layouts

- There should be a way for layouts for a given session to be saved to file and loaded back again, i.e. if you have 2 tabs in a session and each of the tabs has 2 panes, reloading it will restore this
- Configurable allowlist of processes that should be relaunched when restoring a layout, e.g. nvim, claude, ssh

### Keyboard shortcut configuration

- Many of the keyboard shortcuts are hardcoded right now, make them configurable

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

- tab_bar_mode = "when_sidebar_hidden_and_multiple_tabs" seems to be broken after we added the override shortcut
- The pane focusing seems to get "out of sync" sometimes - e.g. I'll have a split left and right, and after moving around sometimes it will show "no split to left". If I mouse click into the same pane it will "re-sync" and continues working again for a while. The other thing I notice is that the blue outline moves but the ACTUAL focus (i.e. where I type) stays on the other pane.
  - The trigger seems to be the CLI. Using the CLI shifts the focus ring but doesn't actually change focus between the panes
- Sometimes the tab name is just "exit $PATH", which seems like a bug
- I noticed randomly I coulnd't activate window mode using the shortcut (as in nothing would happen). After activating it through the menu bar it went back to working.
- Switching between dark/light mode doesn't work - the terminal stays in whatever it was launched. Applications inside of the terminal switch fine
- It seems there are some missing macOS permissions. When launching through the CLI via `open Mistty.app` it shows the full zoxide session list. But when opening interactively it only shows SSH sessions in the session manager

## Implemented

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
- Grow/shrink panes (cmd+arrows, 5% delta)
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

### Navigation

- Ctrl-h/j/k/l between panes with smart neovim pass-through
- Cmd-1 through cmd-9 to focus tab by index
- Cmd-]/cmd-[ for next/prev tab (circular)
- Cmd-shift-up/down to cycle between sessions (circular)

### SSH integration

- SSH auto-connect for SSH session types
- Configurable SSH command with per-host overrides in config
- Option modifier bypasses SSH auto-connect on new panes

### Config & preferences

- Config file parsing from ~/.config/mistty/config.toml
- Preference pane (cmd+,) for font size, cursor style, scrollback, sidebar visibility
- Popup definition configuration

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

### Bug fixes

- Sidebar: active tab gets a leading accent bar (clipped to the rounded corner) and tinted background; active session keeps the bold label and accent-tinted process icon
- Zoomed-pane indicator: SF Symbol next to the tab title in both sidebar and tab bar when `tab.zoomedPane != nil`
- Search ranking: running sessions get a 1.5× score boost so an open session outranks a comparable directory/SSH match; subtitle (path/hostname) matches penalized 0.6× so a clean displayName hit beats a scattered match across a long path
- Session manager sort: running sessions pinned to the top in LRU order via a new `MisttySession.lastActivatedAt` updated by `SessionStore.activeSession.didSet`
- Cmd-W routing: both the SwiftUI menu Button and the global `NSEvent` keyDown monitor now check `store.trackedWindows` before posting the close-pane notification, so Cmd-W closes the focused Settings window instead of leaking through to the terminal behind it
- CLI popup "write failed": `IPCClient` now opens a fresh socket per call (the listener is one-shot), unblocking commands that issue multiple RPCs (e.g. `popup open` calling `listSessions` then `openPopup`)
