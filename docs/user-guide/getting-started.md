# Getting started

This guide walks through Mistty's model and the everyday workflow: organizing work into sessions, splitting panes, and jumping around with the session manager.

## The mental model

Mistty nests four things:

```
Window
└── Session        0 or more: a working directory + a group of tabs
    └── Tab        1 or more: a named group of split panes
        └── Pane   1 or more: a single terminal (one shell or program)
```

- A **window** is a macOS window. You can have several.
- A **session** is the organizing unit: it's tied to a working directory, and every new tab or pane inside it starts there. Think "one project = one session." Sessions show up in the sidebar.
- A **tab** groups split panes under one name.
- A **pane** is a single terminal surface running a shell or program.

Contrary to other terminals, when you launch a new window, you will not see any terminal surfaces. Press `Cmd+J` to open the session manager and search for a directory to launch your first session into. New sessions will always create a new tab, and new tabs will always have at least one pane.

## The sidebar

Press `Cmd+S` to toggle the sidebar: an overview of all your open sessions and their tabs. It's the map of your workspace; click any entry to jump to it. Hide it when you want maximum terminal space. The tab bar can be configured to appear automatically only when the sidebar is hidden (see [tab bar visibility](configuration.md#ui)), or it can be hidden completely. Your active tab and session will be highlighted in the sidebar, as will tabs that have recently sent notifications or rung the bell.

## The session manager

`Cmd+J` opens the session manager: a single fuzzy-search palette over four sources at once —

1. **Open sessions** — everything currently in your sidebar.
2. **Recent directories** — pulled from [zoxide](https://github.com/ajeetdsouza/zoxide), ranked by frecency (requires zoxide installed).
3. **SSH hosts** — parsed from your `~/.ssh/config`.
4. **New session** — create one at a directory you type.

Start typing and results filter live across all four. Hit `Return` to act on the selection:

- a **session** → switches to it
- a **directory** → opens a new session there
- an **SSH host** → opens a new session running `ssh <host>` (customizable per host — see [`[ssh]`](configuration.md#ssh))

This is the fastest way to get where you're going. If you want to create a session by hand, press the up arrow and hit return instead. Press `Cmd+Opt+R` to rename the current session.

## Tabs

| Shortcut             | Action                                                                                   |
| -------------------- | ---------------------------------------------------------------------------------------- |
| `Cmd+T`              | New tab (inherits the session's working directory, and its SSH connection if any)        |
| `Cmd+Opt+T`          | New tab, plain — a local shell that does _not_ inherit the current pane's SSH connection |
| `Cmd+]` / `Cmd+Down` | Next tab                                                                                 |
| `Cmd+[` / `Cmd+Up`   | Previous tab                                                                             |
| `Cmd+1`…`Cmd+9`      | Focus tab N                                                                              |
| `Cmd+Shift+R`        | Rename the current tab                                                                   |
| `Cmd+Ctrl+W`         | Close the current tab, including all panes contained within                              |

## Splitting panes

Split the focused pane to build a layout:

| Shortcut          | Action                                                            |
| ----------------- | ----------------------------------------------------------------- |
| `Cmd+D`           | Split right (horizontal split)                                    |
| `Cmd+Shift+D`     | Split down (vertical split)                                       |
| `Cmd+Opt+D`       | Split right, without inheriting the current pane's SSH connection |
| `Cmd+Shift+Opt+D` | Split down, without inheriting the current pane's SSH connection  |
| `Cmd+W`           | Close the focused pane                                            |

The active pane will be highlighted. New panes inherit the session's working directory by default.
The "plain" variants open a local shell even when the current pane is an SSH session. To move _between_ panes, focus and resize them, or apply a standard layout, use **window mode** (next).

## Window mode

Press `Cmd+X` to enter window mode — a modal layer where single keys manipulate the pane layout. An on-screen hint bar shows the available keys. Highlights:

- `h` `j` `k` `l` — move focus between panes
- arrow keys — swap panes
- `Cmd`+arrows — resize the focused pane
- `z` — zoom (fullscreen) the focused pane
- `1`–`5` — apply a predefined layout (even-horizontal, even-vertical, main-horizontal, main-vertical, tiled)
- `b` — break the pane out into its own tab
- `m` — move a pane from one tab to another
- `Esc` — exit window mode

The full key map is in [Keyboard shortcuts → Window mode](keyboard-shortcuts.md#window-mode).

## Sessions

| Shortcut                          | Action                                |
| --------------------------------- | ------------------------------------- |
| `Ctrl+1`…`Ctrl+9`                 | Focus session N                       |
| `Cmd+Opt+Down` / `Cmd+Opt+Up`     | Next / previous session               |
| `Cmd+Shift+Down` / `Cmd+Shift+Up` | Move session down / up in the sidebar |
| `Cmd+Opt+R`                       | Rename the current session            |

## Working in scrollback

Press `Cmd+Shift+C` to enter **copy mode** and navigate scrollback, select text, and search, or use **hint mode** to grab/open URLs and file paths on screen. This is its own topic: see [Copy mode](copy-mode.md).

## Where to go next

- Rebind any of these keys, or change the UI: [Configuration](configuration.md).
- Drive Mistty from scripts: [CLI](cli.md).
- The complete shortcut list: [Keyboard shortcuts](keyboard-shortcuts.md).
