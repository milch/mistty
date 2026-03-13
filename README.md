# Mistty

A macOS terminal emulator built on [libghostty](https://github.com/ghostty-org/ghostty) with native session management. Mistty brings tmux-style workflows directly into the terminal — sessions, tabs, split panes, and a fuzzy session switcher, all without a separate multiplexer.

## Features (planned)

- **Session manager** (`Cmd+J`) — fuzzy-find and switch between sessions, recent directories (via zoxide), and SSH hosts
- **Tabs and split panes** — standard terminal multiplexing built in
- **Sidebar** — persistent session tree, collapsible with `Cmd+S`
- **Keyboard-driven** — every function accessible via keyboard shortcut
- **Configurable** — XDG-compliant config at `~/.config/mistty/config.toml`
- **Native macOS** — SwiftUI interface, system integration

## CLI Control

Mistty includes a CLI tool for scripting and automation:

```bash
# Install
just install-cli

# Sessions
mistty-cli session list
mistty-cli session create --name "project" --directory ~/code

# Tabs
mistty-cli tab create --session 1 --name "editor"
mistty-cli tab list --session 1

# Panes
mistty-cli pane active
mistty-cli pane create --tab 1 --direction horizontal
mistty-cli pane send-keys "echo hello"
mistty-cli pane run-command "npm test"

# JSON output (auto-detected when piped, or force with --json)
mistty-cli session list | jq .
mistty-cli session list --json
```

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 16+ (for Swift 6 and the Metal Toolchain)
- [Nix](https://nixos.org/download/) (for the build environment — provides Zig)
- [just](https://github.com/casey/just) (command runner, optional but recommended)

If the Metal Toolchain is not installed, run:

```sh
xcodebuild -downloadComponent MetalToolchain
```

## Setup

```sh
# Clone with submodules
git clone --recurse-submodules https://github.com/your-user/mistty.git
cd mistty

# Or if already cloned:
just setup

# Build libghostty (requires nix for Zig 0.15.2)
just build-libghostty

# Build the app
just build

# Run
just run
```

## Development

| Command | Description |
|---|---|
| `just build` | Build debug |
| `just build-release` | Build release |
| `just run` | Build and run |
| `just test` | Run tests |
| `just clean` | Clean build artifacts |
| `just build-libghostty` | Rebuild libghostty from vendored Ghostty |
| `just dev` | Enter nix dev shell |
| `just fmt` | Format Swift code |
| `just info` | Show project info |

### Nix dev shell

The project uses a Nix flake to provide Zig 0.15.2 (required by Ghostty's build system). Swift is expected from the system Xcode installation.

```sh
# Enter the shell manually
nix develop

# Or use direnv (with .envrc already configured)
direnv allow
```

### Project structure

```
mistty/
  Mistty/              # App source
    MisttyApp.swift     # App entry point
    ContentView.swift   # Root SwiftUI view
    Spike/              # libghostty integration spike (temporary)
  MisttyTests/          # Tests
  vendor/ghostty/       # Ghostty git submodule
  docs/
    plans/              # Design and implementation docs
    spike/              # libghostty API research
  Package.swift         # Swift package manifest
  flake.nix             # Nix dev environment
  justfile              # Task runner
```

## Architecture

Mistty uses a three-layer architecture:

- **UI Layer** (SwiftUI) — sidebar, session manager, tab bar, terminal views
- **Session Layer** (Swift protocols) — `SessionStore` > `MisttySession` > `MisttyTab` > `MisttyPane`, designed for future migration from in-memory to a background daemon
- **Terminal Layer** (libghostty) — `NSViewRepresentable` wrapping a `ghostty_surface_t` for terminal rendering

See [docs/plans/2026-03-06-mistty-design.md](docs/plans/2026-03-06-mistty-design.md) for the full design document.

## License

TBD
