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

### Copy mode improvements

- Visual line mode
- Visual block mode
- number prefix (10j jumps 10 lines down, etc...)
- Escaping out of visual mode should return to copy mode, not escape out of copy mode completely
- w/W/e/E/b/B/ge/gE should work as expected (currently w/b are simple 5-char jumps)
- f/F/t/T/; should work as expected
- Actually move through scrollback - current copy mode implementation only covers the contents of the screen
- Search hit highlighting
- ? support (reverse search)
- Copy mode improvement, "yank mode":
  - Press y to enter yank mode while in copy mode
  - Automatically highlight visible links, file paths, hashes, numbers, etc.
  - They receive a non-movement shortcut label next to them, e.g. "a"
  - Pressing the label copies the text to the system clipboard
  - Specifically for links and file paths, there is a slight variant - if entering "yank mode" by pressing `o` instead of `y`, it instead automatically runs `open` on the item

### Save layouts

- There should be a way for layouts for a given session to be saved to file and loaded back again, i.e. if you have 2 tabs in a session and each of the tabs has 2 panes, reloading it will restore this
- Configurable allowlist of processes that should be relaunched when restoring a layout, e.g. nvim, claude, ssh

### Ghostty config

- Ghostty config needs to be configurable too. At least some of the options, not all - those that control the UI, for example, don't apply for mistty, but things like rendering (e.g. display colorspace) do apply

### Keyboard shortcut configuration

- Many of the keyboard shortcuts are hardcoded right now, make them configurable

### UI improvements

- Better minimal tab bar design
- Tab bar should only show when there is more than 1 tab
- Session manager icons (SFSymbols?) indicating the type of each row (currently uses Unicode icons)
- macOS title bar should be hidden
- Hiding/showing the sidebar should be animated (slide in/out)
- Sidebar should show process icons for common processes (can use whatever nvim-mini/mini.icons does for filetype and common terminal icons)
- Instead of showing process title + directory for the tab name in the sidebar, let's only show the CWD (of the currently active pane) for the session and the process title or renamed name for the tab
- mistty-cli should be able to open a markdown file with full rendering support. This overlays a markdown view over the terminal (make sure to respect light/dark mode when rendering!) `mistty-cli open --{markdown,md} <file>`
  - supports rendering mermaid diagrams & images
  - Obsidian markdown support
  - hitting "e" opens the file in $EDITOR for editing, closing the file goes back to the markdown view and shows the updated render
  - Excalidraw rendering support?

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

- Enter/exit copy mode
- Vim navigation: h/j/k/l cursor movement, 0/$ line start/end, g/G top/bottom
- Visual mode (v) with selection highlighting
- Search (/) with case-insensitive matching, n for next match
- Yank selection to clipboard (y) via ghostty_surface_read_text
- Basic word movement (w/b, simplified 5-char jumps)

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
