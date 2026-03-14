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

## Features (v0)

- Session workflow described above
- Standard terminal functions:
  - New tab
  - Rename tab (shows frontmost process name by default)
  - New split pane (horizontal/vertical)
- Sidebar showing all open sessions, with the session's tabs nested.
  - Tabs for each session can be collapsed by clicking on a chevron next to the session name
  - Sidebar is collapsible with cmd+s similar to Arc. Shows on hover when collapsed
  - Sidebar should show when there is bell activity on any tab
- "window mode"
  - Hit keyboard shortcut (cmd+x)
  - Toast window pops up that allows common window management functions:
    - Grow/shrink currently active pane with h/j/k/l (by 5 rows/columns with shift)
    - Swap panes in direction with arrow keys
    - Break pane with b (move pane to new tab)
    - Merge pane with m (move pane to existing tab)
      - Pressing m first brings up the list of open tabs to move the pane to
      - Press 1, 2, 3, ..., to move the pane to that numbered tab
    - o to rotate panes clockwise / O to rotate counter-clockwise
    - Press number keys to switch standard layouts
      1. even-horizontal
      2. even-vertical
      3. main-horizontal
      4. main-vertical
      5. tiled
    - s to save layout for this session / r to restore layout
- "copy mode" from tmux, i.e. after entering copy mode, users can move around the scrollback with vim keybindings and copy text
- Native macOS UI with beautiful design, and following standard macOS paradigms
- Preference pane for common settings. Enables configuration of

## Features (v1)

- CLI control support - create new windows, sessions, panes, and so on [done]
  - Could use AppleScript or some other macOS IPC mechanism
- Popup support - open a new pane that fills the screen and starts with a specific launch command
  - Configurable width/height based on screen size
  - Configurable launch command
  - Configurable whether process exiting closes the popup
  - Launch both via CLI or configure in preference pane: can set up several keyboard shortcuts that will launch a popup (size / command)
- Ghostty config needs to be configurable too. At least some of the options, not all - those that control the UI, for example, don't apply for mistty, but things like rendering (e.g. display colorspace) do apply
- Save layouts
  - There should be a way for layouts for a given session to be saved to file and loaded back again, i.e. if you have 2 tabs in a session and each of the tabs has 2 panes, reloading it will restore this
  - Configurable allowlist of processes that should be relaunched when restoring a layout, e.g. nvim, claude, ssh
- UX improvements
  - Session manager list should be sorted by frecency
  - Session manager typing should fuzzy-filter the list
  - Opening a new sessions should:
    - for directories, open a terminal in that directory. New panes in that session should start in that directory as well
    - for ssh sessions, the first terminal should automatically ssh into that host. new panes do the same by default, unless holding opt (i.e. cmd-d opens a split that ssh's automatically, cmd-opt-d opens a new pane without ssh)
  - Make ssh command configurable, with per-host overrides in preference panes
    - e.g. set "et" for some hosts but not others
  - Navigation between focused panes using Ctrl-h/j/k/l. Should support smart-splits pass through to running neovim processes so it can seamlessly navigate between mistty panes and
  - Switch tabs using standard macOS shortcuts
    - cmd-1/2/3, ... , to focus first tab, second tab, etc.
    - cmd-][ to go to next/prev tab
    - cmd-shift-up/down to move between sessions (in sidebar order)
  - Current session should be hidden in the session manager
  - Window mode:
    - Support the layouts described above
    - Support the reverse operation of "break to tab" (join to tab)
  - Copy mode
    - Visual line mode
    - Visual block mode
    - Escaping out of visual mode should return to copy mode, not escape out of copy mode completely
    - w/W/e/E/b/B/ge/gE/gb/gB should work as expected
    - f/F/t/T/; should work as expected
    - Actually move through scrollback - current copy mode implementation only covers the contents of the screen
    - Search hit highlighting
    - ? support
- UI improvements
  - Better minimal tab bar design
  - Sidebar should highlight the current session & current tab
  - Tab bar should only show when there is more than 1 tab
  - Session manager icons (SFSymbols?) indicating the type of each row
  - macOS title bar should be hidden
  - Double clicking on the tab title should allow rename
  - Hiding/showing the sidebar should be animated (slide in/out)
  - Sidebar should show process icons for common processes (can use whatever nvim-mini/mini.icons does for filetype and common terminal icons)
