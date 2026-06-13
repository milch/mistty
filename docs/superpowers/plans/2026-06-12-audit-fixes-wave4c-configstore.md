# Audit Fixes Wave 4c: ConfigStore Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Eliminate the view-layer config dual-path: `MisttyApp` holds a `@State config = MisttyConfig.current` snapshot threaded down to `WindowRootView`/`ContentView`, while the same code *also* reads `MisttyConfig.current` directly — after a reload the two can disagree within one render pass (audit finding #6, the lowest-severity item). Replace the threaded snapshot with an injected `@Observable ConfigStore` that owns the current config and updates on `.misttyConfigDidReload`, so the view layer has a single, reactive source of truth.

**Scope decision — view layer only:** `MisttyConfig.current` is read from 27 sites in 13 files. Most are non-view services/models/AppKit code (`WindowsStore`, `WindowState`, `IPCService`, `ZoxideService`, `NotificationService`, `TerminalSurfaceView`, `GhosttyApp`, `AppDelegate`, `CopyModeController` via config passed in) that can't take `@Environment` and where the global is the right bootstrap source. The audit explicitly says "keep the static only for bootstrap." So: introduce `ConfigStore` as the source of truth the **views** observe; leave non-view `.current` reads as-is. `ConfigStore` wraps the static (reads through it, refreshes on reload) so there is exactly one underlying value — no second copy that can drift.

**Tech Stack:** Swift/SwiftPM, SwiftUI `@Observable`, XCTest. Baseline: 23 ChromePolish failures = green.

---

### Task 1: `ConfigStore` (TDD)

**Files:** new `Mistty/Config/ConfigStore.swift`, new `MisttyTests/Config/ConfigStoreTests.swift`.

- [ ] Test: a fresh `ConfigStore` exposes `MisttyConfig.current`; after `refresh()` it reflects a changed `MisttyConfig.current`; it refreshes when `.misttyConfigDidReload` posts.

```swift
@MainActor
final class ConfigStoreTests: XCTestCase {
  func test_config_reflectsCurrentAtInit() {
    let store = ConfigStore()
    XCTAssertEqual(store.config.sidebarVisible, MisttyConfig.current.sidebarVisible)
  }

  func test_refresh_picksUpReload() {
    let store = ConfigStore()
    let original = MisttyConfig.current
    defer { MisttyConfig.current = original }
    var changed = original
    changed.sidebarVisible.toggle()
    MisttyConfig.current = changed
    NotificationCenter.default.post(name: .misttyConfigDidReload, object: nil)
    XCTAssertEqual(store.config.sidebarVisible, changed.sidebarVisible)
  }
}
```

- [ ] Implement:

```swift
import Foundation
import Observation

/// Single source of truth for config in the SwiftUI view layer. Wraps the
/// `MisttyConfig.current` bootstrap global and refreshes on reload, so views
/// observe one reactive value instead of carrying a `@State` snapshot that
/// can drift from `.current` within a render pass (audit finding #6).
@MainActor
@Observable
final class ConfigStore {
  private(set) var config: MisttyConfig

  @ObservationIgnored private var observer: NSObjectProtocol?

  init() {
    config = MisttyConfig.current
    observer = NotificationCenter.default.addObserver(
      forName: .misttyConfigDidReload, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  /// Re-read the current config (after a reload or an in-place Settings save).
  func refresh() { config = MisttyConfig.current }
}
```

- [ ] Red → green. Commit: `feat(config): ConfigStore observing MisttyConfig.current` (+ Co-Authored-By trailer, all commits).

---

### Task 2: Inject `ConfigStore`; replace the `@State config` snapshot

**Files:** `Mistty/App/MisttyApp.swift`, `Mistty/App/WindowRootView.swift`, `Mistty/App/ContentView.swift`.

Thread `ConfigStore` exactly the way `windowsStore`/`commandRouter` are already threaded (constructor params, not `@Environment`, to match the codebase idiom).

- [ ] `MisttyApp`: replace `@State private var config: MisttyConfig = MisttyConfig.current` with `@State private var configStore = ConfigStore()`. Anywhere `MisttyApp` reads `config`, read `configStore.config`. Pass `configStore` to `WindowRootView` instead of `config`. (The menu's `config.popups`/`config.shortcuts.*` reads become `configStore.config.*`.)
- [ ] `WindowRootView`: replace `let config: MisttyConfig` with `let configStore: ConfigStore`; pass it to `ContentView`. Update the `misttyConfigDidReload`-driven view work if any reads `config`.
- [ ] `ContentView`: replace `var config: MisttyConfig` with `var configStore: ConfigStore`; replace its `config.*` reads with `configStore.config.*`. (ContentView's direct `MisttyConfig.current` reads inside the copy-mode keystroke path stay as-is — that's per-event resolution, not render state.)
- [ ] Update the 6 `ChromePolishSnapshotTests` ContentView construction sites + any `WindowRootView`/`ContentView` previews to pass a `ConfigStore` (construct one; it reads `.current`).
- [ ] Build + full suite at baseline. Commit: `refactor(config): inject ConfigStore into the view tree`.

---

### Task 3: Route the remaining view-layer `.current` reads through the store

**Files:** `Mistty/Views/Settings/SettingsView.swift`, `Mistty/Views/SessionManager/SessionManagerViewModel.swift`, and any other SwiftUI view still reading `MisttyConfig.current` for *render* state (NOT services/models/AppKit).

- [ ] For each SwiftUI **view** that reads `MisttyConfig.current` to drive rendering, take an injected `ConfigStore` and read `configStore.config`. `SettingsView` is special: it edits config and calls `MisttyConfig.save()` then `reload()` — after a successful save/reload it should call `configStore.refresh()` (or rely on the `.misttyConfigDidReload` post that `reload()` already fires, which the store observes — verify which path Settings uses and keep one).
- [ ] LEAVE unchanged (documented non-goals): `WindowsStore`, `WindowState`, `IPCService`, `ZoxideService`, `NotificationService`, `TerminalSurfaceView`, `GhosttyApp`, `AppDelegate`, `CopyModeController`. These read the bootstrap global by design.
- [ ] Build + full suite at baseline. Acceptance: `grep -rn "MisttyConfig.current" Mistty/Views/` shows only non-render or intentionally-global reads (document any left). Commit: `refactor(config): view layer reads ConfigStore, not the global`.

---

### Final verification
- [ ] Full suite baseline-only; ConfigStoreTests green. If running the app: change a setting in Settings → the sidebar/tab-bar/font reflect it without a relaunch (reactive update through the store).

## Risk notes for the executor
- `ConfigStore` is `@MainActor`; every injection site is already main-actor (SwiftUI views). Do not hand it to the nonisolated IPC/socket code.
- Keep ONE refresh trigger (the `.misttyConfigDidReload` observer). Don't also poll.
- This fixes a render-consistency nit, not a crash/leak — if any step fights the type-checker or risks behavior change, prefer leaving a `.current` read in place and noting it over forcing the conversion.
