# Copy-mode yank fix + config reload — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make copy-mode yank produce correct text when the selection spans more than one screen, and add a `Reload Config` flow (menu + CLI + Settings save) that swaps `MisttyConfig.current` and live-pushes a fresh `ghostty_config_t` so font/scrollback/palette/etc. update without restart.

**Architecture:** Item 1 patches libghostty's `Selection.pin` to make the y-clamp tag-aware (so `SCREEN`/`HISTORY` selections can address scrollback), plus a small Mistty-side normalization in the `.visual` yank case. Item 2 turns `MisttyConfig.loadedAtLaunch` (static `let`) into `MisttyConfig.current` (static `var`) with a `reload()` swap, posts a `misttyConfigDidReload` notification, listens in `GhosttyAppManager` to push through `ghostty_app_update_config`, and listens in `MisttyApp`/`TerminalSurfaceView`/`ZoxideService`/`SettingsView` for SwiftUI propagation.

**Tech Stack:** Swift / SwiftUI / AppKit (macOS 14+), Zig (libghostty patch), XCTest, ArgumentParser (CLI).

**Spec:** `docs/superpowers/specs/2026-04-25-copy-mode-yank-and-config-reload-design.md`

---

## File Structure

| File | Role |
| --- | --- |
| `patches/ghostty/0004-screen-tag-pin-clamp.patch` | New libghostty patch: tag-aware y-clamp in `Selection.pin`. |
| `Mistty/App/ContentView.swift:1466-1475` | Normalize `(anchor, cursor)` in `.visual` yank. |
| `MisttyTests/Models/CopyModeIntegrationTests.swift` | Regression tests for normalization + multi-screen coord computation. |
| `Mistty/Config/MisttyConfig.swift` | Replace `loadedAtLaunch` with `current` + `lastParseError`; add `reload()`; declare `Notification.Name.misttyConfigDidReload`. |
| `MisttyTests/Config/MisttyConfigTests.swift` | Tests for `reload()` success / parse-error / notification. |
| `Mistty/App/GhosttyApp.swift` | Extract `buildGhosttyConfig(from:)`; add `reloadConfig()`; listen for `misttyConfigDidReload`; track retired `ghostty_config_t`. |
| `Mistty/App/MisttyApp.swift` | `let config` → `@State var config`; `.onReceive` reload handler that re-applies title-bar style; new `View → Reload Config` menu item; new `Notification.Name.misttyReloadConfig` trigger. |
| `Mistty/App/AppDelegate.swift` | Replace `loadedAtLaunch.config.restore` with `MisttyConfig.current.restore`. |
| `Mistty/Services/ZoxideService.swift` | Listen for `misttyConfigDidReload` to clear the resolved-path cache. |
| `Mistty/Views/Settings/SettingsView.swift` | After `saveConfig()`, call `MisttyConfig.reload()`; add inline error banner; listen for external reloads to refresh `@State`. |
| `Mistty/Services/IPCService.swift` | Add `reloadConfig(reply:)` method that runs the same flow as the menu trigger. |
| `Mistty/Services/IPCListener.swift:308` | Route `reloadConfig` method through to the service. |
| `MisttyShared/MisttyServiceProtocol.swift` | Add `func reloadConfig(reply:)` to the protocol. |
| `MisttyCLI/Commands/ConfigCommand.swift` | Add `Reload` subcommand. |

---

## Pre-flight

This work touches libghostty and SwiftUI startup paths. Recommend running it on an isolated worktree:

```bash
git worktree add .worktrees/yank-and-reload -b yank-and-reload main
just setup-worktree     # in .worktrees/yank-and-reload
```

The libghostty rebuild in Task 2 requires Xcode ≤ 26.3 (zig 0.15.2 limitation — see the hint in `just build-libghostty`). If you can't build libghostty locally, copy `vendor/ghostty/macos/GhosttyKit.xcframework` from a machine that can.

---

# Item 1 — Multi-screen copy-mode yank

## Task 1: Add the libghostty `pin()` clamp patch

**Files:**
- Create: `patches/ghostty/0004-screen-tag-pin-clamp.patch`

The local Zig enum at `vendor/ghostty/src/apprt/embedded.zig:1320-1325` is:

```zig
const Tag = enum(c_int) {
    active = 0,
    viewport = 1,
    screen = 2,
    history = 3,
};
```

so the patch uses bare lowercase cases (no `GHOSTTY_POINT_` prefix).

- [ ] **Step 1: Create the patch file**

Write `patches/ghostty/0004-screen-tag-pin-clamp.patch` with these exact contents:

```diff
diff --git a/src/apprt/embedded.zig b/src/apprt/embedded.zig
index 3241d02ad..0000000 100644
--- a/src/apprt/embedded.zig
+++ b/src/apprt/embedded.zig
@@ -1343,9 +1343,16 @@ pub const CAPI = struct {
                 ),
             };
 
-            // Clamp our point to the screen bounds.
+            // Clamp our point to the screen bounds. The max y depends on the
+            // tag: `active` and `viewport` are bounded by the visible
+            // viewport height, while `screen` and `history` can address
+            // scrollback and so are bounded by `total_rows`.
+            const max_y: usize = switch (self.tag) {
+                .active, .viewport => screen.pages.rows,
+                .screen, .history => screen.pages.total_rows,
+            };
             const clamped_x = @min(self.x, screen.pages.cols -| 1);
-            const clamped_y = @min(self.y, screen.pages.rows -| 1);
+            const clamped_y = @min(self.y, max_y -| 1);
 
             return switch (self.coord_tag) {
                 // Exact coordinates require a specific pin.
```

- [ ] **Step 2: Apply the patch and confirm clean apply**

```bash
just patch-ghostty 2>&1 | tee /tmp/mistty-patch.log
grep -E "Applying|Skipping" /tmp/mistty-patch.log
```

Expected: a line `Applying patches/ghostty/0004-screen-tag-pin-clamp.patch`. The other three patches should print `Skipping … (already applied or does not apply)`.

- [ ] **Step 3: Verify the source change landed**

```bash
sed -n '1340,1360p' vendor/ghostty/src/apprt/embedded.zig
```

Expected: the new `max_y` switch is present right above `clamped_x`.

- [ ] **Step 4: Commit the patch file**

```bash
git add patches/ghostty/0004-screen-tag-pin-clamp.patch
git commit -m "patches(ghostty): tag-aware y-clamp in Selection.pin

SCREEN and HISTORY selections can address scrollback rows past the
viewport. The previous unconditional clamp to viewport rows-1
collapsed any cross-viewport read_text request to a single row near
the top of the visible area."
```

## Task 2: Rebuild libghostty with the patch

**Files:**
- Rebuilds: `vendor/ghostty/macos/GhosttyKit.xcframework`

- [ ] **Step 1: Rebuild libghostty**

```bash
just build-libghostty 2>&1 | tee /tmp/mistty-libghostty.log
```

Expected: completes with no error. (See note about Xcode 26.4+ in the recipe hint if it fails.)

- [ ] **Step 2: Confirm the framework was rebuilt**

```bash
ls -la vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64*/Headers/ghostty.h
```

Expected: `ghostty.h` modified time within the last few minutes.

- [ ] **Step 3: Confirm Mistty still builds against the new framework**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log | tail -5
```

Expected: build succeeds. No new warnings or errors related to selections.

(No commit — the framework is gitignored. The patch file commit in Task 1 is the canonical record of the change.)

## Task 3: Mistty `.visual` yank normalization (TDD)

**Files:**
- Modify: `Mistty/App/ContentView.swift:1466-1475`
- Modify: `MisttyTests/Models/CopyModeIntegrationTests.swift`

The current `.visual` branch passes `(anchor.row, anchor.col)` as `top_left` and `(cursorRow, cursorCol)` as `bottom_right`. When the cursor lies lexicographically before the anchor, ghostty receives an inverted region. Normalize to whichever endpoint is smaller in `(row, col)` order.

We can't unit-test the libghostty call itself (it needs a live surface), so the test target is a small pure helper extracted from the yank logic.

- [ ] **Step 1: Add a failing unit test**

Append the following test to `MisttyTests/Models/CopyModeIntegrationTests.swift` (after the last existing test; preserve the file's existing imports and class declaration):

```swift
  func test_visualYankNormalizes_whenCursorBeforeAnchor() {
    // (row=5, col=10) anchor; (row=2, col=3) cursor.
    let (top, bottom) = CopyModeYank.normalize(
      anchor: (row: 5, col: 10),
      cursor: (row: 2, col: 3)
    )
    XCTAssertEqual(top.row, 2)
    XCTAssertEqual(top.col, 3)
    XCTAssertEqual(bottom.row, 5)
    XCTAssertEqual(bottom.col, 10)
  }

  func test_visualYankNormalizes_whenSameRowCursorBefore() {
    let (top, bottom) = CopyModeYank.normalize(
      anchor: (row: 4, col: 20),
      cursor: (row: 4, col: 5)
    )
    XCTAssertEqual(top.col, 5)
    XCTAssertEqual(bottom.col, 20)
  }

  func test_visualYankNormalizes_whenAnchorBeforeCursor() {
    let (top, bottom) = CopyModeYank.normalize(
      anchor: (row: 1, col: 0),
      cursor: (row: 99, col: 0)
    )
    XCTAssertEqual(top.row, 1)
    XCTAssertEqual(bottom.row, 99)
  }
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
swift test --filter CopyModeIntegrationTests/test_visualYankNormalizes 2>&1 | tee /tmp/mistty-test.log | tail -20
```

Expected: compile error — `CopyModeYank` is undefined.

- [ ] **Step 3: Add the helper**

Create the new namespace next to `CopyModeState`. Append the following extension at the bottom of `Mistty/Models/CopyModeState.swift` (after the closing brace of the `CopyModeState` struct):

```swift
enum CopyModeYank {
  /// Lexicographic min/max on `(row, col)` so callers can pass `top_left`
  /// and `bottom_right` to `ghostty_surface_read_text` in the order ghostty
  /// requires.
  static func normalize(
    anchor: (row: Int, col: Int),
    cursor: (row: Int, col: Int)
  ) -> (top: (row: Int, col: Int), bottom: (row: Int, col: Int)) {
    let aFirst = anchor.row < cursor.row
      || (anchor.row == cursor.row && anchor.col <= cursor.col)
    return aFirst ? (anchor, cursor) : (cursor, anchor)
  }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
swift test --filter CopyModeIntegrationTests/test_visualYankNormalizes 2>&1 | tee /tmp/mistty-test.log | tail -10
```

Expected: 3 tests passed.

- [ ] **Step 5: Use the helper in `yankSelection()`**

Replace the `.visual` branch in `Mistty/App/ContentView.swift:1466-1475` with:

```swift
    case .visual:
      let (top, bottom) = CopyModeYank.normalize(
        anchor: (row: anchor.row + offset, col: anchor.col),
        cursor: (row: state.cursorRow + offset, col: state.cursorCol)
      )
      textToCopy = readGhosttyText(
        surface: surface,
        startRow: top.row, startCol: top.col,
        endRow: bottom.row, endCol: bottom.col,
        rectangle: false,
        pointTag: tag
      )
```

- [ ] **Step 6: Run the full test suite**

```bash
swift test 2>&1 | tee /tmp/mistty-test.log | tail -20
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Mistty/Models/CopyModeState.swift Mistty/App/ContentView.swift \
        MisttyTests/Models/CopyModeIntegrationTests.swift
git commit -m "fix(copy-mode): normalize visual-mode yank endpoints

Reverse character-wise selections (cursor before anchor) sent ghostty
inverted top_left/bottom_right and read_text returned wrong/empty
text. Match the visualLine/visualBlock pattern with a lexicographic
min/max on (row, col)."
```

## Task 4: Manual verification of multi-screen yank

**Files:** none (verification only)

- [ ] **Step 1: Build and bundle**

```bash
just bundle 2>&1 | tail -5
open build/Mistty-dev.app
```

- [ ] **Step 2: Reproduce the original bug fixed**

In a Mistty pane, run:

```bash
yes "line $(uuidgen)" | head -n 200
```

Then:

1. Press `cmd+shift+c` to enter copy mode.
2. Press `V` for visual line mode.
3. Press `Ctrl-u` enough times to scroll to the start of the dump.
4. Press `y`.
5. Paste into a different app (or `pbpaste | wc -l`).

Expected: ~200 lines pasted, not one.

- [ ] **Step 3: Reproduce the secondary `.visual` normalization fix**

Same setup. Then:

1. Place the cursor near the bottom of an output region.
2. Enter copy mode (`cmd+shift+c`).
3. Press `v` (character-wise).
4. Press `5k` then `2h` so the cursor ends up lexicographically before the anchor.
5. Press `y` and paste.

Expected: the highlighted text matches what was pasted.

(No commit — verification only.)

---

# Item 2 — Config reload

## Task 5: `MisttyConfig.current` + `reload()` + notification (TDD)

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift`
- Modify: `MisttyTests/Config/MisttyConfigTests.swift`

The existing `loadedAtLaunch: (config:parseError:)` static `let` runs once per process. We replace it with a mutable cache:

```swift
static var current: MisttyConfig
static var lastParseError: Error?
@discardableResult
static func reload(from url: URL = configURL) throws -> MisttyConfig
```

Plus a notification name: `Notification.Name.misttyConfigDidReload`.

- [ ] **Step 1: Add failing tests**

Open `MisttyTests/Config/MisttyConfigTests.swift` and add the following block at the end of the existing test class (preserving imports + class declaration):

```swift
  func test_reload_swapsCurrent_onSuccess() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-reload-\(UUID().uuidString).toml")
    try "font_size = 16\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let original = MisttyConfig.current
    defer { MisttyConfig.current = original }

    let observer = expectation(forNotification: .misttyConfigDidReload, object: nil)
    let result = try MisttyConfig.reload(from: url)
    wait(for: [observer], timeout: 1.0)

    XCTAssertEqual(result.fontSize, 16)
    XCTAssertEqual(MisttyConfig.current.fontSize, 16)
  }

  func test_reload_keepsCurrent_onParseError() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-reload-bad-\(UUID().uuidString).toml")
    try? "this is = not [valid toml\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    var snapshot = MisttyConfig()
    snapshot.fontSize = 42
    let original = MisttyConfig.current
    defer { MisttyConfig.current = original }
    MisttyConfig.current = snapshot

    XCTAssertThrowsError(try MisttyConfig.reload(from: url))
    XCTAssertEqual(MisttyConfig.current.fontSize, 42)
  }
```

- [ ] **Step 2: Run them and confirm failure**

```bash
swift test --filter MisttyConfigTests 2>&1 | tee /tmp/mistty-test.log | tail -10
```

Expected: compile errors — `MisttyConfig.current`, `MisttyConfig.reload`, and `Notification.Name.misttyConfigDidReload` are undefined.

- [ ] **Step 3: Replace `loadedAtLaunch` with `current` + `reload()`**

In `Mistty/Config/MisttyConfig.swift`, replace the existing `loadedAtLaunch` definition (lines 376-383) and the `load()` definition (lines 371-373) with:

```swift
  /// Mutable cache of the parsed config. Initialized on first read; swapped
  /// by `reload()`. All consumers should read this (or call `load()`).
  nonisolated(unsafe) static var current: MisttyConfig = {
    do {
      let cfg = try loadThrowing()
      return cfg
    } catch {
      lastParseError = error
      return .default
    }
  }()

  /// Most-recent parse error, set by the `current` initializer or by a
  /// failed `reload()` (in which case `current` is left unchanged).
  nonisolated(unsafe) static var lastParseError: Error? = nil

  /// Convenience accessor for code that doesn't care about the parse error
  /// surface. Returns `current`.
  static func load() -> MisttyConfig { current }

  /// Re-parse the config file from disk and atomically swap `current`. On
  /// success posts `.misttyConfigDidReload` and returns the new value. On
  /// parse error throws (and leaves `current` unchanged).
  @discardableResult
  static func reload(from url: URL = configURL) throws -> MisttyConfig {
    let new = try loadThrowing(from: url)
    current = new
    lastParseError = nil
    NotificationCenter.default.post(name: .misttyConfigDidReload, object: nil)
    return new
  }
```

- [ ] **Step 4: Add the notification name**

At the bottom of `Mistty/Config/MisttyConfig.swift` (outside the `MisttyConfig` struct), add:

```swift
extension Notification.Name {
  /// Posted by `MisttyConfig.reload()` after `current` has been swapped.
  /// Listeners that hold cached values should refresh from `MisttyConfig.current`.
  static let misttyConfigDidReload = Notification.Name("misttyConfigDidReload")
}
```

- [ ] **Step 5: Migrate existing `loadedAtLaunch` callers**

Replace the three remaining `loadedAtLaunch` references with `current`:

```bash
grep -rn "loadedAtLaunch" Mistty MisttyShared MisttyCLI
```

Expected hits: `Mistty/App/MisttyApp.swift:15`, `Mistty/App/GhosttyApp.swift:231`, `Mistty/App/AppDelegate.swift:50`, `Mistty/Views/Terminal/TerminalSurfaceView.swift:68`, `Mistty/Views/Terminal/TerminalSurfaceView.swift:629`, `Mistty/Services/ZoxideService.swift:65`.

For each, change `MisttyConfig.loadedAtLaunch.config` to `MisttyConfig.current` and drop the parse-error tuple. The parse-error path in `Mistty/App/GhosttyApp.swift:231-257` becomes:

```swift
    let misttyConfig = MisttyConfig.current
    if let parseError = MisttyConfig.lastParseError {
      // ... existing alert body unchanged
    }
```

(The `MisttyApp.swift` and `AppDelegate.swift` changes are simple text replacements.)

- [ ] **Step 6: Run the tests and confirm they pass**

```bash
swift test --filter MisttyConfigTests 2>&1 | tee /tmp/mistty-test.log | tail -10
swift build 2>&1 | tee /tmp/mistty-build.log | tail -5
```

Expected: 2 new tests pass; all existing tests still pass; build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift Mistty/App/MisttyApp.swift \
        Mistty/App/GhosttyApp.swift Mistty/App/AppDelegate.swift \
        Mistty/Views/Terminal/TerminalSurfaceView.swift \
        Mistty/Services/ZoxideService.swift \
        MisttyTests/Config/MisttyConfigTests.swift
git commit -m "config: mutable current + reload() + notification

Replaces the static-let cache with MisttyConfig.current and a reload()
method that re-parses the TOML, swaps the cache, and posts
.misttyConfigDidReload. No consumers wired yet — they'll listen in
follow-up commits."
```

## Task 6: GhosttyAppManager — extract config builder, add `reloadConfig()`

**Files:**
- Modify: `Mistty/App/GhosttyApp.swift`

The existing init builds a `ghostty_config_t` inline (lines 211-280). Extract that into a helper so reload can call the same flow.

- [ ] **Step 1: Extract `buildGhosttyConfig` helper**

In `Mistty/App/GhosttyApp.swift`, add this method to `GhosttyAppManager` (right after `tick()`):

```swift
  /// Build a fresh `ghostty_config_t` from the current `MisttyConfig`,
  /// loading `~/.config/mistty/ghostty.conf` first and then applying our
  /// resolved overrides via a temp file. Caller is responsible for its
  /// lifetime — pass to `ghostty_app_update_config` then retain until the
  /// next reload (or app shutdown).
  private func buildGhosttyConfig(from misttyConfig: MisttyConfig) -> ghostty_config_t? {
    guard let cfg = ghostty_config_new() else {
      print("[GhosttyAppManager] ghostty_config_new failed")
      return nil
    }

    let misttyConfigPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/mistty/ghostty.conf").path
    if FileManager.default.fileExists(atPath: misttyConfigPath) {
      misttyConfigPath.withCString { path in
        ghostty_config_load_file(cfg, path)
      }
    }

    let ghosttyLines = misttyConfig.ghosttyConfigLines
    if !ghosttyLines.isEmpty {
      let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mistty-ghostty-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).conf")
      let contents = ghosttyLines.joined(separator: "\n") + "\n"
      if (try? contents.write(to: tempURL, atomically: true, encoding: .utf8)) != nil {
        tempURL.path.withCString { path in
          ghostty_config_load_file(cfg, path)
        }
      }
    }

    ghostty_config_finalize(cfg)
    return cfg
  }
```

- [ ] **Step 2: Replace the inline build in `init` with a call to the helper**

In `GhosttyAppManager.init()`, replace lines roughly 210-280 (from `// 2. Create and load config` through `ghostty_config_finalize(cfg)` and the `self.config = cfg` assignment) with:

```swift
    // 2. Build initial config
    let misttyConfig = MisttyConfig.current
    if let parseError = MisttyConfig.lastParseError {
      let message = describeTOMLParseError(parseError)
      Task { @MainActor in
        let notifications = NotificationCenter.default.notifications(
          named: NSApplication.didFinishLaunchingNotification
        )
        for await _ in notifications {
          NSApp.activate(ignoringOtherApps: true)
          let alert = NSAlert()
          alert.alertStyle = .warning
          alert.messageText = "Mistty could not parse config.toml"
          alert.informativeText =
            "Falling back to defaults.\n\n\(message)\n\nFile: \(MisttyConfig.configURL.path)"
          alert.addButton(withTitle: "OK")
          alert.runModal()
          break
        }
      }
    }

    guard let cfg = buildGhosttyConfig(from: misttyConfig) else { return }
    self.config = cfg
    sharedGhosttyConfig = cfg

    let diagCount = ghostty_config_diagnostics_count(cfg)
    for i in 0..<diagCount {
      let diag = ghostty_config_get_diagnostic(cfg, i)
      if let msg = diag.message {
        print("[GhosttyAppManager] config diagnostic: \(String(cString: msg))")
      }
    }
```

(The runtime-config build, app creation, and appearance observer below stay as-is.)

- [ ] **Step 3: Add a retired-config list + `reloadConfig()` method**

Add a stored property to `GhosttyAppManager`:

```swift
  /// Configs from prior reloads. We don't free these synchronously after
  /// `ghostty_app_update_config` because surface message processing may
  /// still hold references. Freed in `deinit`.
  nonisolated(unsafe) private var retiredConfigs: [ghostty_config_t] = []
```

Add a public method on `GhosttyAppManager`:

```swift
  /// Re-parse the user's `~/.config/mistty/ghostty.conf` + the resolved
  /// passthrough lines and push the new config to ghostty. The previous
  /// `ghostty_config_t` is retired and freed on app shutdown.
  func reloadConfig() {
    guard let app = self.app else { return }
    guard let newCfg = buildGhosttyConfig(from: MisttyConfig.current) else { return }

    if let old = self.config {
      retiredConfigs.append(old)
    }
    self.config = newCfg
    sharedGhosttyConfig = newCfg
    ghostty_app_update_config(app, newCfg)

    let diagCount = ghostty_config_diagnostics_count(newCfg)
    for i in 0..<diagCount {
      let diag = ghostty_config_get_diagnostic(newCfg, i)
      if let msg = diag.message {
        print("[GhosttyAppManager] reload diagnostic: \(String(cString: msg))")
      }
    }
  }
```

- [ ] **Step 4: Free retired configs in `deinit`**

Replace the existing `deinit` body with:

```swift
  deinit {
    if let app { ghostty_app_free(app) }
    if let config { ghostty_config_free(config) }
    for cfg in retiredConfigs { ghostty_config_free(cfg) }
  }
```

- [ ] **Step 5: Wire the notification listener in `init()`**

Right after the existing `appearanceObserver = ...` block in `init()`, add:

```swift
    // Re-push the ghostty config when MisttyConfig.reload() runs.
    NotificationCenter.default.addObserver(
      forName: .misttyConfigDidReload,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reloadConfig()
      }
    }
```

- [ ] **Step 6: Build to verify**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log | tail -5
```

Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Mistty/App/GhosttyApp.swift
git commit -m "ghostty: reloadConfig() pushes fresh config to libghostty

Extracts the inline config-build flow from init into
buildGhosttyConfig(from:) and adds reloadConfig() that rebuilds + calls
ghostty_app_update_config. Old configs go on a retired list and are
freed at app shutdown to dodge in-flight surface message races."
```

## Task 7: Reactive root view + Reload Config menu item

**Files:**
- Modify: `Mistty/App/MisttyApp.swift`

- [ ] **Step 1: Make `config` observable + add reload listener**

In `Mistty/App/MisttyApp.swift`, change:

```swift
  private let config: MisttyConfig = MisttyConfig.loadedAtLaunch.config
```

to:

```swift
  @State private var config: MisttyConfig = MisttyConfig.current
```

(The `loadedAtLaunch` rename in Task 5 may have already partially handled this — verify.)

In the `body` property of `MisttyApp`, on the `WindowGroup`'s root view (the `ContentView(...)` ... `.applyTopSafeArea(...)` chain), add:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .misttyConfigDidReload)) { _ in
          config = MisttyConfig.current
          applyTitleBarStyleToWindows()
        }
```

- [ ] **Step 2: Add the menu item + trigger notification**

Add a new notification name. In the `Notification.Name` extension at the bottom of `MisttyApp.swift`, add:

```swift
  static let misttyReloadConfig = Notification.Name("misttyReloadConfig")
```

Add a `Reload Config` menu button. Inside `.commands { CommandGroup(after: .toolbar) { … } }`, add (the placement is your call — putting it next to the other config-touching items, after "Toggle Tab Bar", is a good fit):

```swift
        Button("Reload Config") {
          NotificationCenter.default.post(name: .misttyReloadConfig, object: nil)
        }
```

- [ ] **Step 3: Listen for the trigger and call `MisttyConfig.reload()`**

In the `body` of `MisttyApp`, on the `WindowGroup`'s root view (same chain as Step 1), add:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .misttyReloadConfig)) { _ in
          do {
            try MisttyConfig.reload()
          } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Mistty could not reload config.toml"
            alert.informativeText =
              "\(describeTOMLParseError(error))\n\nFile: \(MisttyConfig.configURL.path)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
          }
        }
```

(`describeTOMLParseError` lives in `MisttyShared/Config/GhosttyConfig.swift` and is already imported in `GhosttyApp.swift`. Add `import MisttyShared` to `MisttyApp.swift` if not already present.)

- [ ] **Step 4: Build + sanity check**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log | tail -5
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Mistty/App/MisttyApp.swift
git commit -m "ui: View > Reload Config menu item + reactive config @State

Hooks the menu trigger through .misttyReloadConfig (matching the
existing notification-driven menu pattern) and refreshes the root
view's config @State on .misttyConfigDidReload so the tab bar /
title bar / pane border / popups all re-render. Parse errors surface
via the same NSAlert flow used at launch."
```

## Task 8: ZoxideService — invalidate cached probe on reload

**Files:**
- Modify: `Mistty/Services/ZoxideService.swift`

Most existing `MisttyConfig.loadedAtLaunch` callers (now `MisttyConfig.current` after Task 5) read the cache on each use, so they pick up reloads automatically. The two cases worth checking:

- `TerminalSurfaceView.scrollWheel` (line 629) reads `scrollMultiplier` per event → live after Task 5, no extra work.
- `TerminalSurfaceView.init` (line 68) reads `ui.contentPadding*` to set initial padding for the ghostty surface → padding flows through `ghostty_app_update_config` after Task 6, so existing surfaces get the new values.
- `ZoxideService` caches the *resolved zoxide path* in an actor (`CachedExecutable.resolved`). The probe runs once and the result is memoized regardless of `MisttyConfig.current` changes. This is the only one that needs an explicit invalidation.

- [ ] **Step 1: Expose a `clear()` on `CachedExecutable`**

In `Mistty/Services/ZoxideService.swift`, in the private `actor CachedExecutable` (lines 51-100), add:

```swift
    func clear() {
      resolved = nil
    }
```

- [ ] **Step 2: Add a notification observer in `ZoxideService.init`**

Find `ZoxideService`'s init (or static initialiser). If there's no instance init yet, add one. Register a one-line observer that calls `clear()` on the cache:

```swift
  init() {
    NotificationCenter.default.addObserver(
      forName: .misttyConfigDidReload,
      object: nil,
      queue: .main
    ) { [cache = self.cache] _ in
      Task { await cache.clear() }
    }
  }
```

(Adapt the `cache` reference to whatever the existing field is named — the file holds the `CachedExecutable` somewhere reachable from the service.)

- [ ] **Step 3: Build + sanity check**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log | tail -5
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Services/ZoxideService.swift
git commit -m "config: ZoxideService re-probes after config reload

The cached zoxide path persisted across MisttyConfig.reload() so a
new zoxide_path override didn't take effect without a restart.
Listening for .misttyConfigDidReload clears the cache so the next
session-manager open re-probes."
```

## Task 9: SettingsView — reload after save, inline error banner

**Files:**
- Modify: `Mistty/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Add error state + helper**

Add a `@State` for the inline error and rework `saveConfig()` to call `reload()`:

```swift
  @State private var saveError: String?
```

Replace the existing `saveConfig()` (line 240-242) with:

```swift
  private func saveConfig() {
    do {
      try config.save()
      try MisttyConfig.reload()
      saveError = nil
    } catch {
      saveError = describeTOMLParseError(error)
    }
  }
```

(Add `import MisttyShared` at the top of the file if not already imported. Verify `describeTOMLParseError` is exposed there.)

- [ ] **Step 2: Surface the banner**

Just inside `Form { ... }`, before the first `Section`, add:

```swift
      if let saveError {
        Text("Could not save / reload: \(saveError)")
          .foregroundStyle(.red)
          .font(.callout)
          .padding(.vertical, 4)
      }
```

- [ ] **Step 3: Refresh on external reload**

Add a `.onReceive` to the `Form`:

```swift
    .onReceive(NotificationCenter.default.publisher(for: .misttyConfigDidReload)) { _ in
      // External reload (menu, CLI) — pick up whatever was just swapped in.
      config = MisttyConfig.current
      saveError = nil
    }
```

- [ ] **Step 4: Build + sanity**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log | tail -5
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/Settings/SettingsView.swift
git commit -m "settings: reload config cache after save; show parse errors inline

saveConfig() now writes the file AND calls MisttyConfig.reload() so
the running app picks up edits without a restart. Parse errors land
on an inline banner instead of being silently swallowed by 'try?'."
```

## Task 10: IPC `reloadConfig` RPC + CLI subcommand

**Files:**
- Modify: `MisttyShared/MisttyServiceProtocol.swift`
- Modify: `Mistty/Services/IPCService.swift`
- Modify: `Mistty/Services/IPCListener.swift`
- Modify: `MisttyCLI/Commands/ConfigCommand.swift`

- [ ] **Step 1: Add the protocol method**

In `MisttyShared/MisttyServiceProtocol.swift`, just before the closing brace of the protocol, in the `// MARK: - Debug` group (or in a new `// MARK: - Config` group right above it), add:

```swift
    // MARK: - Config

    func reloadConfig(reply: @escaping (Data?, Error?) -> Void)
```

- [ ] **Step 2: Implement in IPCService**

In `Mistty/Services/IPCService.swift`, just after `getStateSnapshot` (around line 552-566), add:

```swift
  // MARK: - Config

  func reloadConfig(reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      do {
        try MisttyConfig.reload()
        reply(Data("{}".utf8), nil)
      } catch {
        reply(nil, MisttyIPC.error(.operationFailed,
          "Could not reload config: \(describeTOMLParseError(error))"))
      }
    }
  }
```

- [ ] **Step 3: Route in IPCListener**

In `Mistty/Services/IPCListener.swift`, in the method dispatch switch (around line 305), add a case right after `"getStateSnapshot"`:

```swift
    case "reloadConfig":
      service.reloadConfig(reply: reply)
```

- [ ] **Step 4: Add the CLI subcommand**

In `MisttyCLI/Commands/ConfigCommand.swift`, register a new subcommand on the parent `ConfigCommand`. Change:

```swift
    subcommands: [Show.self]
```

to:

```swift
    subcommands: [Show.self, Reload.self]
```

Then, inside the `ConfigCommand` struct (after the `Show` subcommand definition), add:

```swift
  struct Reload: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Tell the running Mistty instance to re-read ~/.config/mistty/config.toml."
    )

    func run() throws {
      let client = try IPCClient()
      _ = try client.call("reloadConfig")
    }
  }
```

Verify `IPCClient` import — `import MisttyShared` should already be at the top of the file.

- [ ] **Step 5: Build the CLI + binary**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log | tail -5
```

Expected: build succeeds. Both `Mistty` and `MisttyCLI` targets compile.

- [ ] **Step 6: Commit**

```bash
git add MisttyShared/MisttyServiceProtocol.swift \
        Mistty/Services/IPCService.swift \
        Mistty/Services/IPCListener.swift \
        MisttyCLI/Commands/ConfigCommand.swift
git commit -m "cli: mistty-cli config reload triggers in-process reload

New reloadConfig IPC RPC funnels into MisttyConfig.reload() — the
same entry point the menu and SettingsView save use."
```

## Task 11: Manual end-to-end verification of reload

**Files:** none (verification only)

- [ ] **Step 1: Build + bundle**

```bash
just bundle 2>&1 | tail -5
open build/Mistty-dev.app
```

- [ ] **Step 2: Verify menu reload, multiple knobs**

In a Mistty pane:

1. Edit `~/.config/mistty/config.toml`. Add (or change) `font_size = 18` under the top-level keys.
2. Click `View → Reload Config` (or whatever menu the item landed under).
3. Expected: terminal text resizes immediately.
4. Edit again: change `[ui] pane_border_color = "#ff0000"`.
5. Reload.
6. Expected: pane split borders turn red without restart.
7. Edit again: change `[ui] tab_bar_mode = "always"`.
8. Reload.
9. Expected: tab bar shows immediately even with one tab.

- [ ] **Step 3: Verify CLI reload**

Edit `config.toml` again, change `font_size` back to `13`. From a pane:

```bash
mistty-cli config reload
```

Expected: command exits 0; terminal text resizes.

- [ ] **Step 4: Verify Settings save reload**

Open `Cmd+,`. Change Font Size to `15`. Tab away.
Expected: terminal text resizes immediately.

- [ ] **Step 5: Verify parse-error path**

Edit `config.toml` and corrupt it (e.g. `font_size = "not a number"` or missing closing bracket).

- Trigger via menu → expect NSAlert with the error.
- Trigger via CLI → expect non-zero exit with the error printed to stderr.
- Trigger via Settings save → expect inline red banner in the form.

In all three cases, dismiss the error, fix the file, reload again — should succeed.

(No commit — verification only.)

---

## Final cleanup

- [ ] **Step 1: Confirm full test suite green**

```bash
swift test 2>&1 | tee /tmp/mistty-test.log | tail -20
```

Expected: all tests pass.

- [ ] **Step 2: Confirm no stale `loadedAtLaunch` references**

```bash
grep -rn "loadedAtLaunch" Mistty MisttyShared MisttyCLI MisttyTests
```

Expected: no hits.

- [ ] **Step 3: Update PLAN.md (on `main` only — see AGENTS.md)**

Switch back to `main`, edit PLAN.md to move both items from `### Misc & Bugs` into `## Implemented`, and mention the new patch + reload flow under `### Bug fixes` and a new `### Config reload` heading respectively.
