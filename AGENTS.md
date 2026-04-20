## AGENTS.md

Project: Mistty — macOS terminal emulator (Swift/SwiftUI + AppKit, libghostty-backed).

### Build / test
- `swift build` — debug build
- `swift test` — run full XCTest suite
- `just bundle` — package `build/Mistty-dev.app` for `open`-launching

Pipe long-running command output to a log file and grep it (long raw output wastes context).

### Git worktrees
When working on an isolated branch via `git worktree add .worktrees/<name> -b <branch> main`, the new worktree does NOT have `vendor/ghostty` initialized and does NOT have `GhosttyKit.xcframework` (it's a gitignored build artifact). Builds will fail until those are in place.

**Always run `just setup-worktree` after creating a secondary worktree.** The recipe:
- Initializes the `vendor/ghostty` submodule
- Symlinks `vendor/ghostty/macos/GhosttyKit.xcframework` from the main checkout

If the main checkout doesn't have a prebuilt xcframework, run `just build-libghostty` in the main checkout first (requires the nix devshell).

### Code conventions
- No unsolicited comments; never narrate what code does if names already tell you.
- No trailing summary docs unless the user asked for them.
- Tests over speculation — unit-test logic that can be unit-tested; rely on manual verification for AppKit-integration paths.
- Don't modify `PLAN.md` on feature branches — the user edits it on `main` directly.
