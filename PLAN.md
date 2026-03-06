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

## Features

- Session workflow described above
- Standard terminal functions:
  - New tab
  - Rename tab (shows frontmost process name by default)
  - New split pane (horizontal/vertical)
- Sidebar showing all open sessions, with the session's tabs nested.
  - Tabs for each session can be collapsed by clicking on a chevron next to the session name
  - Sidebar is collapsible with cmd+s similar to Arc. Shows on hover when collapsed
  - Sidebar should show when there is bell activity on any tab
- Save layouts
  - There should be a way for layouts for a given session to be saved to file and loaded back again, i.e. if you have 2 tabs in a session and each of the tabs has 2 panes, reloading it will restore this
  - Configurable allowlist of processes that should be relaunched when restoring a layout, e.g. nvim, claude, ssh
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
