# Mistty

A native macOS terminal built on [libghostty](https://github.com/ghostty-org/ghostty), with tmux-style session management built in. Sessions, tabs, split panes, and a fuzzy switcher live inside the terminal — no separate multiplexer to run, configure, or keep alive.

The same, GPU-accelerated rendering engine you are used to from Ghostty. Mistty wraps it in a SwiftUI shell that organizes your work into a tree of windows, sessions, tabs, and panes you can drive entirely from the keyboard or script from the command line.

> Requires macOS 14 (Sonoma) or later on Apple Silicon.

## Features

- **Session manager** (`Cmd+J`) — one fuzzy palette over your open sessions, recent directories (via [zoxide](https://github.com/ajeetdsouza/zoxide)), and SSH hosts from `~/.ssh/config`. Type a few letters, hit return, and you're in the right place.
- **Sessions, tabs, and split panes** — a working-directory-scoped session holds tabs; tabs hold split panes. Standard terminal multiplexing without tmux.
- **Sidebar** (`Cmd+S`) — a persistent tree of your sessions and tabs.
- **Popups** — launch TUIs like `lazygit` or quick commands you run all the time by binding them to a keyboard shortcut.
- **Window mode** (`Cmd+X`) — a modal layer for moving, resizing, zooming, and rearranging panes with single keystrokes, plus one-key standard layouts.
- **Copy mode** (`Cmd+Shift+C`) — vim-style keyboard navigation, selection, search, and link/path hints for yanking or opening without the mouse. Also try **yank mode** (`Cmd+Shift+V`) or **copy mode** (`Cmd+Shift+O`) to copy or open text shaped like numbers, URLs, paths, and more, with a few keystrokes.
- **State restoration** — relaunch and your sessions, tabs, panes, and working directories come back; allow-listed programs (nvim, ssh, …) relaunch too. Configure restoration strategies like passing environment variables, or repeating the previous arguments.
- **CLI control** (`mistty-cli`) — script sessions, tabs, and panes; send keys, run commands, and read pane text over a local socket.
- **Configurable** — a single TOML file at `~/.config/mistty/config.toml`, plus full passthrough to any [Ghostty option](https://ghostty.org/docs/config/reference).
- **Desktop notifications** — programs can raise a macOS notification (OSC 9 / 777) from inside a pane; the originating tab and the Dock icon are flagged when it's not focused. `claude`, `codex`, or other agent harnesses will be highlighted in the sidebar when they are waiting for your response.

## Install

### Homebrew (recommended)

```sh
brew install --cask milch/mistty/mistty
```

This installs `Mistty.app` and puts the `mistty-cli` tool on your `PATH`.

It is recommended to install [zoxide](https://github.com/ajeetdsouza/zoxide) to populate recent directories in the session manager:

```sh
brew install zoxide
```

### Build from source

See [Building from source](docs/user-guide/installation.md#building-from-source) — you'll need Xcode, [Nix](https://nixos.org/download/) (for the pinned Zig that builds libghostty), and [just](https://github.com/casey/just).

## Quick start

Launch Mistty and you get one window with a single session, tab, and pane. From there:

| Shortcut                | Action                                                             |
| ----------------------- | ------------------------------------------------------------------ |
| `Cmd+J`                 | Session manager — jump to a session, recent directory, or SSH host |
| `Cmd+T`                 | New tab                                                            |
| `Cmd+D` / `Cmd+Shift+D` | Split pane right / down                                            |
| `Cmd+X`                 | Window mode — move, resize, zoom, and lay out panes                |
| `Cmd+Shift+C`           | Copy mode — keyboard scrollback, selection, and link hints         |
| `Cmd+S`                 | Toggle the sidebar                                                 |
| `Cmd+1`…`Cmd+9`         | Focus tab N (`Ctrl+1`…`9` focus session N)                         |

Every shortcut is rebindable. The [keyboard shortcuts reference](docs/user-guide/keyboard-shortcuts.md) lists them all.

## Documentation

The [**user guide**](docs/user-guide/README.md) covers everything in depth:

- [Installation](docs/user-guide/installation.md) — Homebrew, zoxide, and building from source
- [Getting started](docs/user-guide/getting-started.md) — windows, sessions, tabs, panes, and the session manager
- [Keyboard shortcuts](docs/user-guide/keyboard-shortcuts.md) — every binding, plus window mode
- [Copy mode](docs/user-guide/copy-mode.md) — vim-style navigation and link hints
- [Configuration](docs/user-guide/configuration.md) — the full `config.toml` reference
- [CLI](docs/user-guide/cli.md) — scripting Mistty with `mistty-cli`

A fully-commented sample config lives at [`docs/config-example.toml`](docs/config-example.toml). There's also a [Neovim smart-splits integration](docs/integrations/neovim-smart-splits.md) for seamless vim ↔ pane navigation.

## Development

| Command                 | Description                                            |
| ----------------------- | ------------------------------------------------------ |
| `just setup`            | Initialize submodules (first-time)                     |
| `just build-libghostty` | Build libghostty from the vendored Ghostty (needs Nix) |
| `just build`            | Build the app (debug)                                  |
| `just run`              | Build, install to `/Applications`, and launch          |
| `just test`             | Run the test suite                                     |
| `just fmt`              | Format Swift sources                                   |
| `just info`             | Show project info                                      |

Run `just --list` for the full set. The architecture and contributor notes live in [`docs/user-guide/installation.md`](docs/user-guide/installation.md) and the design docs under [`docs/`](docs/).

## License

[MIT](LICENSE).
