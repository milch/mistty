# Installation

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (the release build is `arm64`-only)

## Homebrew

```sh
brew install --cask milch/mistty/mistty
```

That single command taps [`milch/homebrew-mistty`](https://github.com/milch/homebrew-mistty), installs `Mistty.app` into `/Applications`, and symlinks the `mistty-cli` command onto your `PATH`. Newer versions of homebrew might require you to run a `brew trust` command to allow installation.

To upgrade later:

```sh
brew upgrade --cask mistty
```

To uninstall (and remove its preferences and caches):

```sh
brew uninstall --cask --zap mistty
```

### Recommended: zoxide

The session manager lists your recent directories by querying [zoxide](https://github.com/ajeetdsouza/zoxide). Mistty works fine without it, you just won't see the recent-directories section. To enable it:

```sh
brew install zoxide
```

Mistty finds `zoxide` automatically across common install locations (Homebrew, Nix, cargo, `~/.local/bin`). If yours lives somewhere unusual, point at it explicitly with [`zoxide_path`](configuration.md#top-level-options) in your config.

## Building from source

Mistty links against `libghostty`, which is built from a vendored Ghostty submodule using a specific Zig version. The build environment is provided by Nix.

### Prerequisites

- **Xcode** (for the Swift 6 toolchain and the Metal toolchain). If the Metal toolchain is missing, run `xcodebuild -downloadComponent MetalToolchain`.
- **[Nix](https://nixos.org/download/)** — provides the pinned Zig (0.15.2) that Ghostty's build system requires.
- **[just](https://github.com/casey/just)** — the task runner (recommended).

> **Xcode version note:** Zig 0.15.2 cannot link against the Xcode 26.4+ macOS SDK. If `just build-libghostty` fails with a flood of `undefined symbol` errors, switch to an older Xcode (`sudo xcode-select --switch /Applications/Xcode-26.3.app`) or build the xcframework elsewhere and copy it in. `just build-libghostty` prints this hint automatically on failure.

### Steps

```sh
# Clone with the Ghostty submodule
git clone --recurse-submodules https://github.com/milch/mistty.git
cd mistty

# (If you cloned without --recurse-submodules)
just setup

# Build libghostty from the vendored Ghostty (requires Nix)
just build-libghostty

# Build, install to /Applications, and launch
just run
```

`just run` produces `Mistty-dev.app` — a separate bundle identifier from the release build, so a source build and a Homebrew install can coexist without clobbering each other's saved state. It also symlinks `mistty-cli` into `~/.local/bin`; add that directory to your `PATH` if it isn't already.

### Common tasks

| Command                 | Description                                  |
| ----------------------- | -------------------------------------------- |
| `just build`            | Build debug                                  |
| `just build-release`    | Build release                                |
| `just run`              | Build, install (debug), and launch           |
| `just run-release`      | Build, install (release), and launch         |
| `just test`             | Run the test suite (skips benchmarks)        |
| `just bench`            | Run benchmarks in release config             |
| `just fmt`              | Format Swift sources (needs `swift-format`)  |
| `just clean`            | Remove build artifacts                       |
| `just build-libghostty` | Rebuild libghostty from the vendored Ghostty |
| `just dev`              | Enter the Nix dev shell                      |
| `just info`             | Show project info                            |

Run `just --list` for the complete set, including release packaging, version bumping, and worktree helpers.

### Nix dev shell

The Nix flake supplies Zig 0.15.2; Swift comes from your system Xcode. Enter it manually with `nix develop`, or use [direnv](https://direnv.net/) (`direnv allow` — an `.envrc` is already configured) to load it automatically when you `cd` into the repo.
