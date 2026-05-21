# OSC Desktop Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a macOS desktop notification when a program in a pane emits an OSC 9 or OSC 777 notification escape sequence.

**Architecture:** libghostty already parses OSC 9 / OSC 777 and fires a `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` action. A new case in Mistty's ghostty action callback re-broadcasts it as an in-process `NotificationCenter` event. A new global `NotificationService` singleton consumes that event exactly once, flags the emitting tab (reusing the bell indicator + Dock badge), and posts a `UNUserNotificationCenter` banner. No changes to vendored ghostty.

**Tech Stack:** Swift 6, SwiftPM (no `.xcodeproj` — files under `Mistty/` are auto-discovered), `UserNotifications` framework, `TOMLKit`, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-21-osc-notifications-design.md`

---

## Background for the implementer

- **Build:** `swift build` compiles the app. `just test` runs `swift test --skip Benchmark`. Run a single test with `swift test --filter <Suite>/<method>`. These commands are slow — pipe to a log file and grep the log rather than re-running.
- **Statically-typed TDD note:** in Swift, a test that references a not-yet-defined type or function fails by *failing to compile*, not by a runtime assertion. For the "verify it fails" steps below, a build error naming the missing symbol IS the expected red state.
- **`MisttyConfig`** (`Mistty/Config/MisttyConfig.swift`) is a `Sendable, Equatable` value type. It holds nested config structs (`SSHConfig`, `UIConfig`, `CopyModeHintsConfig`, …) defined in the same file. `MisttyConfig.parse(_:)` parses TOML; `save(to:)` re-serializes; `MisttyConfig.current` is the live cache; `reload()` swaps it and posts `.misttyConfigDidReload`.
- **Ghostty action callback** lives in `Mistty/App/GhosttyApp.swift` — a C function pointer (`actionCallback`) that switches on `action.tag`. Surface-targeted cases convert any C-string payloads to Swift `String` *synchronously* (the `action` struct is only valid for the callback's duration), then `DispatchQueue.main.async` and post a `Notification.Name`. The `Notification.Name` values are declared in an `extension Notification.Name` in the same file.
- **`WindowsStore`** (`Mistty/Models/WindowsStore.swift`, `@Observable @MainActor`) is the global window registry. `pane(byId:)` returns `(window, session, tab, pane)`. `activeWindow` tracks the key terminal window. `trackedNSWindow(byId:)` maps a window id to its `NSWindow`.
- **Bell precedent:** `ContentView.handleRingBell` (`Mistty/App/ContentView.swift:746`) resolves the pane, computes "is the user looking at this tab", sets `tab.hasBell = true` if not, and calls `updateDockBadge()`. `updateDockBadge()` (`ContentView.swift:778`) is currently a `private` method but its body only touches global state.
- **C payload:** `ghostty.h` defines `ghostty_action_desktop_notification_s { const char* title; const char* body; }`, the enum case `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`, and the union member `desktop_notification`. Access as `action.action.desktop_notification`.

---

## File Structure

- **Modify** `Mistty/Config/MisttyConfig.swift` — add `NotificationsConfig` struct, a `notifications` field, parse + save support.
- **Modify** `Mistty/Models/WindowsStore.swift` — add a public `updateDockBadge()` method.
- **Modify** `Mistty/App/ContentView.swift` — delete the private `updateDockBadge()`, route its 6 call sites to `windowsStore.updateDockBadge()`.
- **Modify** `Mistty/App/GhosttyApp.swift` — add the `.ghosttyDesktopNotification` name and a `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` case.
- **Create** `Mistty/Services/NotificationService.swift` — two file-scope pure helper functions plus the `NotificationService` singleton class.
- **Modify** `Mistty/App/MisttyApp.swift` — call `NotificationService.shared.start(...)` in `init()`.
- **Modify** `MisttyTests/Config/MisttyConfigTests.swift` — `NotificationsConfig` parse + round-trip tests.
- **Create** `MisttyTests/Services/NotificationServiceTests.swift` — tests for the two pure helpers.
- **Modify** `docs/config-example.toml` — document `[notifications]`.
- **Modify** `PLAN.md` — move the item to Implemented; record OSC 99 as a follow-up.

---

## Task 1: `NotificationsConfig` type, parsing, and serialization

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift`
- Test: `MisttyTests/Config/MisttyConfigTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these methods to the `MisttyConfigTests` class in `MisttyTests/Config/MisttyConfigTests.swift` (before the closing brace):

```swift
  func test_notifications_defaultEnabled() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertTrue(config.notifications.enabled)
    XCTAssertFalse(config.notifications.explicitlyEnabled)
  }

  func test_notifications_explicitTrue() throws {
    let toml = """
      [notifications]
      enabled = true
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertTrue(config.notifications.enabled)
    XCTAssertTrue(config.notifications.explicitlyEnabled)
  }

  func test_notifications_explicitFalse() throws {
    let toml = """
      [notifications]
      enabled = false
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertFalse(config.notifications.enabled)
    XCTAssertFalse(config.notifications.explicitlyEnabled)
  }

  func test_notifications_emptyTableUsesDefaults() throws {
    let config = try MisttyConfig.parse("[notifications]")
    XCTAssertTrue(config.notifications.enabled)
    XCTAssertFalse(config.notifications.explicitlyEnabled)
  }

  func test_save_notifications_roundTrip_explicitTrue() throws {
    var config = MisttyConfig()
    config.notifications = NotificationsConfig(enabled: true, explicitlyEnabled: true)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-notif-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.notifications, config.notifications)
  }

  func test_save_notifications_roundTrip_explicitFalse() throws {
    var config = MisttyConfig()
    config.notifications = NotificationsConfig(enabled: false, explicitlyEnabled: false)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-notif-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.notifications, config.notifications)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MisttyConfigTests/test_notifications 2>&1 | tee /tmp/mistty-test.log | tail -20`
Expected: build failure — `cannot find 'NotificationsConfig' in scope` and `value of type 'MisttyConfig' has no member 'notifications'`.

- [ ] **Step 3: Add the `NotificationsConfig` struct**

In `Mistty/Config/MisttyConfig.swift`, add this struct immediately after the `CopyModeHintsConfig` struct (right before `enum TabBarMode`):

```swift
/// Desktop-notification settings. `enabled` is the master switch (default
/// `true`). `explicitlyEnabled` is `true` only when the user literally wrote
/// `enabled = true` in `[notifications]` — it drives the eager
/// authorization request at launch (see `NotificationService`).
struct NotificationsConfig: Sendable, Equatable {
  var enabled: Bool = true
  var explicitlyEnabled: Bool = false
}
```

- [ ] **Step 4: Add the `notifications` field to `MisttyConfig`**

In `struct MisttyConfig`, add this stored property right after `var restore: RestoreConfig = RestoreConfig()`:

```swift
  var notifications: NotificationsConfig = NotificationsConfig()
```

- [ ] **Step 5: Parse `[notifications]` in `MisttyConfig.parse`**

In `static func parse(_:)`, add this block immediately after the `if let restoreTable = ...` block and before `return config`:

```swift
    if let notifTable = table["notifications"]?.table {
      if let enabled = notifTable["enabled"]?.bool {
        config.notifications.enabled = enabled
        config.notifications.explicitlyEnabled = enabled
      }
    }
```

- [ ] **Step 6: Serialize `[notifications]` in `MisttyConfig.save`**

In `func save(to:)`, add this block immediately after the `if ui != UIConfig() { ... }` block and before the `let defaultBindings = ShortcutAction.defaults` line:

```swift
    if notifications != NotificationsConfig() {
      lines.append("")
      lines.append("[notifications]")
      lines.append("enabled = \(notifications.enabled)")
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter MisttyConfigTests/test_notifications 2>&1 | tee /tmp/mistty-test.log | tail -20`
Expected: PASS — `Executed 6 tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift MisttyTests/Config/MisttyConfigTests.swift
git commit -m "feat(config): add [notifications] config table"
```

---

## Task 2: Move `updateDockBadge()` onto `WindowsStore`

This is a pure refactor — no behavior change, no new test. The dock-badge logic depends on `NSApp`, so it is verified by build + the manual checks in Task 8.

**Files:**
- Modify: `Mistty/Models/WindowsStore.swift`
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Add `updateDockBadge()` to `WindowsStore`**

In `Mistty/Models/WindowsStore.swift`, add this method inside the `WindowsStore` class, immediately before the `// MARK: - Restore helpers` line:

```swift
  // MARK: - Dock badge

  /// Set the Dock icon badge to the number of background tabs with an active
  /// bell. Called on bell ring, on desktop notification, and on tab-switch
  /// (which clears `hasBell` for the newly-active tab). No-ops when `NSApp`
  /// isn't yet available (tests).
  func updateDockBadge() {
    let count = windows
      .flatMap(\.sessions)
      .flatMap(\.tabs)
      .filter(\.hasBell)
      .count
    NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
  }
```

Note: `NSApp` is `NSApplication!` — use optional chaining (`NSApp?.dockTile`) so the method is a safe no-op under `swift test` where `NSApp` is nil. The old `ContentView` version used `NSApp.dockTile` directly; this is a deliberate hardening since the method is now reachable from a service.

- [ ] **Step 2: Delete the private `updateDockBadge()` from `ContentView`**

In `Mistty/App/ContentView.swift`, delete the entire private method (the doc comment + `private func updateDockBadge() { ... }` block around line 775-785):

```swift
  /// Set the Dock icon badge to the number of background tabs with an active
  /// bell. Called on ring and on tab-switch (which clears `hasBell` for the
  /// newly-active tab). No-ops when `NSApp` isn't yet available (tests).
  private func updateDockBadge() {
    let count = windowsStore.windows
      .flatMap(\.sessions)
      .flatMap(\.tabs)
      .filter(\.hasBell)
      .count
    NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
  }
```

- [ ] **Step 3: Re-point the call sites**

In `Mistty/App/ContentView.swift` there are 6 calls to the bare `updateDockBadge()` (around lines 121, 141, 165, 621, 723, 765). Replace each `updateDockBadge()` call with `windowsStore.updateDockBadge()`.

Run this to confirm none remain after editing:
`rg -n 'updateDockBadge' Mistty/App/ContentView.swift`
Expected: every match is now `windowsStore.updateDockBadge()` — no bare `updateDockBadge()` calls and no `func updateDockBadge`.

- [ ] **Step 4: Build to verify**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log | tail -20`
Expected: `Build complete!` with no errors.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/WindowsStore.swift Mistty/App/ContentView.swift
git commit -m "refactor: move updateDockBadge onto WindowsStore"
```

---

## Task 3: Re-broadcast the ghostty desktop-notification action

Not unit-testable (the callback is a C function pointer driven by libghostty). Verified by build + Task 8.

**Files:**
- Modify: `Mistty/App/GhosttyApp.swift`

- [ ] **Step 1: Add the notification name**

In `Mistty/App/GhosttyApp.swift`, in the `extension Notification.Name` block (around line 180-185), add:

```swift
  static let ghosttyDesktopNotification = Notification.Name("ghosttyDesktopNotification")
```

- [ ] **Step 2: Add the action case**

In the `actionCallback` closure's `switch action.tag`, add this case immediately before the `default:` case:

```swift
  case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      let notification = action.action.desktop_notification
      // Convert the C strings synchronously — `action` is only valid for the
      // duration of this callback.
      let title = notification.title.map { String(cString: $0) } ?? ""
      let body = notification.body.map { String(cString: $0) } ?? ""
      DispatchQueue.main.async {
        guard let userdata = ghostty_surface_userdata(surface) else { return }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        NotificationCenter.default.post(
          name: .ghosttyDesktopNotification,
          object: nil,
          userInfo: ["paneID": view.pane?.id as Any, "title": title, "body": body]
        )
      }
    }
    return true
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log | tail -20`
Expected: `Build complete!` with no errors. (`GHOSTTY_ACTION_DESKTOP_NOTIFICATION` and `desktop_notification` are defined in `vendor/ghostty/include/ghostty.h`.)

- [ ] **Step 4: Commit**

```bash
git add Mistty/App/GhosttyApp.swift
git commit -m "feat(ghostty): re-broadcast desktop-notification action"
```

---

## Task 4: `resolveNotificationTitle` pure helper

**Files:**
- Create: `Mistty/Services/NotificationService.swift`
- Create: `MisttyTests/Services/NotificationServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MisttyTests/Services/NotificationServiceTests.swift`:

```swift
import XCTest

@testable import Mistty

final class NotificationServiceTests: XCTestCase {
  func test_resolveTitle_usesRawTitleWhenPresent() {
    let result = resolveNotificationTitle(
      rawTitle: "Build finished", processTitle: "zsh", sessionLabel: "myproj")
    XCTAssertEqual(result, "Build finished")
  }

  func test_resolveTitle_fallsBackToProcessTitle() {
    let result = resolveNotificationTitle(
      rawTitle: "", processTitle: "nvim", sessionLabel: "myproj")
    XCTAssertEqual(result, "nvim")
  }

  func test_resolveTitle_fallsBackToSessionLabel() {
    let result = resolveNotificationTitle(
      rawTitle: "", processTitle: nil, sessionLabel: "myproj")
    XCTAssertEqual(result, "myproj")
  }

  func test_resolveTitle_fallsBackToMisttyWhenAllEmpty() {
    let result = resolveNotificationTitle(
      rawTitle: "", processTitle: nil, sessionLabel: "")
    XCTAssertEqual(result, "Mistty")
  }

  func test_resolveTitle_treatsWhitespaceOnlyAsEmpty() {
    let result = resolveNotificationTitle(
      rawTitle: "   ", processTitle: "  ", sessionLabel: "myproj")
    XCTAssertEqual(result, "myproj")
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter NotificationServiceTests/test_resolveTitle 2>&1 | tee /tmp/mistty-test.log | tail -20`
Expected: build failure — `cannot find 'resolveNotificationTitle' in scope`.

- [ ] **Step 3: Create `NotificationService.swift` with the helper**

Create `Mistty/Services/NotificationService.swift`:

```swift
import AppKit
import Foundation
import UserNotifications

/// Resolve the title shown in a macOS notification. OSC 9 carries no title,
/// so fall back through the emitting pane's process title, then the session
/// label, then a constant. Whitespace-only values are treated as empty.
func resolveNotificationTitle(
  rawTitle: String, processTitle: String?, sessionLabel: String
) -> String {
  let raw = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  if !raw.isEmpty { return raw }
  if let processTitle = processTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
    !processTitle.isEmpty
  {
    return processTitle
  }
  let label = sessionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
  if !label.isEmpty { return label }
  return "Mistty"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter NotificationServiceTests/test_resolveTitle 2>&1 | tee /tmp/mistty-test.log | tail -20`
Expected: PASS — `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/NotificationService.swift MisttyTests/Services/NotificationServiceTests.swift
git commit -m "feat(notifications): add resolveNotificationTitle helper"
```

---

## Task 5: `isUserViewingTab` pure helper

**Files:**
- Modify: `Mistty/Services/NotificationService.swift`
- Modify: `MisttyTests/Services/NotificationServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Add these methods to `NotificationServiceTests` in `MisttyTests/Services/NotificationServiceTests.swift`:

```swift
  func test_isUserViewingTab_allTrue() {
    XCTAssertTrue(
      isUserViewingTab(
        appActive: true, windowActive: true, sessionActive: true, tabActive: true))
  }

  func test_isUserViewingTab_appBackgrounded() {
    XCTAssertFalse(
      isUserViewingTab(
        appActive: false, windowActive: true, sessionActive: true, tabActive: true))
  }

  func test_isUserViewingTab_differentWindow() {
    XCTAssertFalse(
      isUserViewingTab(
        appActive: true, windowActive: false, sessionActive: true, tabActive: true))
  }

  func test_isUserViewingTab_differentTab() {
    XCTAssertFalse(
      isUserViewingTab(
        appActive: true, windowActive: true, sessionActive: true, tabActive: false))
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter NotificationServiceTests/test_isUserViewingTab 2>&1 | tee /tmp/mistty-test.log | tail -20`
Expected: build failure — `cannot find 'isUserViewingTab' in scope`.

- [ ] **Step 3: Add the helper**

In `Mistty/Services/NotificationService.swift`, add this function immediately after `resolveNotificationTitle`:

```swift
/// True when the user is actively looking at the tab that emitted the
/// notification: Mistty frontmost, its window active, that window's active
/// session matching, and that session's active tab matching. Mirrors
/// `ContentView.handleRingBell`'s visibility check (tab granularity — a
/// visible split-peer pane counts as "seen"). When true, no banner is shown.
func isUserViewingTab(
  appActive: Bool, windowActive: Bool, sessionActive: Bool, tabActive: Bool
) -> Bool {
  appActive && windowActive && sessionActive && tabActive
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter NotificationServiceTests/test_isUserViewingTab 2>&1 | tee /tmp/mistty-test.log | tail -20`
Expected: PASS — `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/NotificationService.swift MisttyTests/Services/NotificationServiceTests.swift
git commit -m "feat(notifications): add isUserViewingTab helper"
```

---

## Task 6: `NotificationService` class + app wiring

Not unit-testable (uses `UNUserNotificationCenter` and `NSApp`, which are unavailable under `swift test`). Verified by build + Task 8.

**Files:**
- Modify: `Mistty/Services/NotificationService.swift`
- Modify: `Mistty/App/MisttyApp.swift`

- [ ] **Step 1: Add the `NotificationService` class**

In `Mistty/Services/NotificationService.swift`, append this class after the two helper functions:

```swift
/// Owns the macOS desktop-notification integration. A single instance
/// (`shared`) consumes the in-process `.ghosttyDesktopNotification` event
/// exactly once — handling it per-window would post one banner per window.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationService()

  private weak var windowsStore: WindowsStore?
  private var didRequestAuthorization = false

  private override init() { super.init() }

  /// Wire up the service. Called once from `MisttyApp.init()` after the
  /// `WindowsStore` exists.
  func start(windowsStore: WindowsStore) {
    self.windowsStore = windowsStore
    UNUserNotificationCenter.current().delegate = self

    NotificationCenter.default.addObserver(
      forName: .ghosttyDesktopNotification, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated { self?.handleDesktopNotification(note) }
    }
    NotificationCenter.default.addObserver(
      forName: .misttyConfigDidReload, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.requestAuthorizationIfExplicitlyEnabled() }
    }

    // Defer the initial eager request one runloop tick so it doesn't run
    // mid-`MisttyApp.init()`.
    DispatchQueue.main.async { [weak self] in
      self?.requestAuthorizationIfExplicitlyEnabled()
    }
  }

  /// Request authorization up front, but only when the user explicitly wrote
  /// `[notifications] enabled = true`. Fresh installs that never touched the
  /// config are not prompted until the first notification actually fires.
  private func requestAuthorizationIfExplicitlyEnabled() {
    guard MisttyConfig.current.notifications.explicitlyEnabled else { return }
    requestAuthorizationIfNeeded()
  }

  /// Request macOS notification authorization at most once per process.
  private func requestAuthorizationIfNeeded() {
    guard !didRequestAuthorization else { return }
    didRequestAuthorization = true
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
  }

  private func handleDesktopNotification(_ note: Notification) {
    guard MisttyConfig.current.notifications.enabled else { return }
    let rawTitle = note.userInfo?["title"] as? String ?? ""
    let body = note.userInfo?["body"] as? String ?? ""
    let paneID = note.userInfo?["paneID"] as? Int

    // Default title for the unresolvable-pane path (pane closed between
    // emission and dispatch, or no surface userdata).
    var title = rawTitle.isEmpty ? "Mistty" : rawTitle
    var threadID: String?

    if let paneID, let store = windowsStore, let resolved = store.pane(byId: paneID) {
      let viewing = isUserViewingTab(
        appActive: NSApp.isActive,
        windowActive: store.activeWindow?.id == resolved.window.id,
        sessionActive: resolved.window.activeSession?.id == resolved.session.id,
        tabActive: resolved.session.activeTab?.id == resolved.tab.id)
      // The user is already looking at the tab — no banner, no flag.
      if viewing { return }
      resolved.tab.hasBell = true
      store.updateDockBadge()
      title = resolveNotificationTitle(
        rawTitle: rawTitle,
        processTitle: resolved.pane.processTitle,
        sessionLabel: resolved.session.sidebarLabel)
      threadID = String(resolved.session.id)
    }

    requestAuthorizationIfNeeded()
    postBanner(title: title, body: body, paneID: paneID, threadID: threadID)
  }

  private func postBanner(title: String, body: String, paneID: Int?, threadID: String?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let threadID { content.threadIdentifier = threadID }
    if let paneID { content.userInfo = ["paneID": paneID] }
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in }
  }

  /// Focus the pane that emitted a notification the user clicked.
  private func focusPane(paneID: Int?) {
    NSApp.activate(ignoringOtherApps: true)
    guard let paneID, let store = windowsStore,
      let resolved = store.pane(byId: paneID)
    else { return }
    store.trackedNSWindow(byId: resolved.window.id)?.window?.makeKeyAndOrderFront(nil)
    resolved.window.activeSession = resolved.session
    resolved.session.activeTab = resolved.tab
    resolved.tab.focusPane(resolved.pane)
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Every banner we post has already passed the `isUserViewingTab` check,
    // so it always deserves to show — including while Mistty is frontmost.
    completionHandler([.banner, .list])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let paneID = response.notification.request.content.userInfo["paneID"] as? Int
    Task { @MainActor in
      self.focusPane(paneID: paneID)
      completionHandler()
    }
  }
}
```

- [ ] **Step 2: Wire `start()` into `MisttyApp.init()`**

In `Mistty/App/MisttyApp.swift`, in `init()`, add this line immediately after `appDelegate.observer = StateRestorationObserver(windowsStore: _windowsStore.wrappedValue)`:

```swift
    NotificationService.shared.start(windowsStore: _windowsStore.wrappedValue)
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log | tail -25`
Expected: `Build complete!` with no errors and no new warnings.

- [ ] **Step 4: Run the full test suite to confirm nothing regressed**

Run: `just test 2>&1 | tee /tmp/mistty-test.log | tail -25`
Expected: all tests pass (`0 failures`). The new `NotificationService` class is not exercised by tests; the suite must still be green.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/NotificationService.swift Mistty/App/MisttyApp.swift
git commit -m "feat(notifications): add NotificationService and wire into app launch"
```

---

## Task 7: Documentation

**Files:**
- Modify: `docs/config-example.toml`
- Modify: `PLAN.md`

- [ ] **Step 1: Document `[notifications]` in the example config**

In `docs/config-example.toml`, insert this block immediately before the `# ─── Window chrome ───` separator line (i.e. after the `uppercase_action = "open"` line and its trailing blank line):

```toml
# ─── Desktop notifications ───────────────────────────────────────────────────
# Mistty raises a macOS notification when a program in a pane emits an OSC 9
# or OSC 777 notification escape sequence (e.g. a "build finished" message).
# A notification from a pane you are not currently looking at also flags its
# tab and the Dock icon, like a terminal bell.
#
# When `enabled` is explicitly set to `true` here, Mistty asks for macOS
# notification permission at launch; otherwise it asks the first time a
# notification fires. Set `enabled = false` to turn the feature off.
# [notifications]
# enabled = true

```

- [ ] **Step 2: Update `PLAN.md` — remove the old TODO line**

In `PLAN.md`, under `### Misc & Bugs` → `Larger:`, replace the line:

```markdown
- OSC777/OSC9/OSC99 notifications support
```

with:

```markdown
- OSC 99 (Kitty notification protocol) — needs a libghostty Zig parser patch (new OSC parser + action plumbing). OSC 9 + OSC 777 shipped (see `## Implemented`). Spec context: `docs/superpowers/specs/2026-05-21-osc-notifications-design.md`.
```

- [ ] **Step 3: Update `PLAN.md` — add the Implemented entry**

In `PLAN.md`, under `## Implemented`, add this new section immediately after the `### Configurable keyboard shortcuts` section (before `### Multi-window v1`):

```markdown
### OSC desktop notifications

Spec: `docs/superpowers/specs/2026-05-21-osc-notifications-design.md`. Plan: `docs/superpowers/plans/2026-05-21-osc-notifications.md`.

- OSC 9 (iTerm2 fallback) and OSC 777 (rxvt) escape sequences raise macOS desktop notifications. libghostty already parses both into a `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` action; a new case in `GhosttyApp.actionCallback` re-broadcasts it as the in-process `.ghosttyDesktopNotification` event
- New global `NotificationService` singleton consumes the event exactly once (per-window handling would post duplicate banners), owns the `UNUserNotificationCenter` delegate, and posts the banner. Clicking a banner activates Mistty and focuses the emitting window/session/tab/pane
- A notification for a tab the user isn't viewing flags the tab via the existing `hasBell` indicator + Dock badge; `updateDockBadge()` moved from `ContentView` onto `WindowsStore` so the service can reach it. The "is the user viewing this tab" check mirrors `handleRingBell` at tab granularity. When Mistty is frontmost on a different pane the banner is forced via the `willPresent` delegate returning `[.banner, .list]`
- `[notifications]` config table with `enabled` (default `true`). Authorization is requested at launch when `enabled` is explicitly `true`, otherwise lazily on the first notification. Rate-limiting / de-duplication are left to libghostty (1/sec, 5s dedup)
- OSC 99 (Kitty notification protocol) deferred — no parser in vendored ghostty; tracked under `### Misc & Bugs`
```

- [ ] **Step 4: Commit**

```bash
git add docs/config-example.toml PLAN.md
git commit -m "docs: document OSC notifications config and update PLAN"
```

---

## Task 8: Manual verification

`UNUserNotificationCenter` only works in the bundled app — run the installed build, not `swift run`.

- [ ] **Step 1: Build and launch the app**

Run: `just run`
Expected: Mistty launches.

- [ ] **Step 2: Background-pane notification shows a banner**

In a Mistty pane, open a second tab so the first tab is in the background, then in that background tab's pane run:
`printf '\e]9;hello from osc9\a'`
Switch focus to the other tab first if needed so the emitting tab is not active. Then trigger it (e.g. via a `sleep 3 && printf ...` so you can switch away).
Expected: a macOS banner titled with the pane's process title (OSC 9 has no title) and body "hello from osc9"; the emitting tab shows the orange bell indicator; the Dock icon shows a badge.

- [ ] **Step 3: OSC 777 carries title + body**

In a background pane run: `printf '\e]777;notify;Build;done\a'`
Expected: a banner titled "Build" with body "done".

- [ ] **Step 4: Focused pane is silent**

Run `printf '\e]9;ignored\a'` in the pane you are currently focused on.
Expected: no banner, no tab flag (you are looking at it). libghostty rate-limiting may also suppress rapid repeats — wait ~2s between tries.

- [ ] **Step 5: Click-to-focus**

Trigger a background-pane notification (Step 2) and click the banner.
Expected: Mistty comes to the front and the emitting tab/pane becomes focused.

- [ ] **Step 6: Config toggle + live reload**

Add to `~/.config/mistty/config.toml`:
```toml
[notifications]
enabled = false
```
Then run `mistty-cli config reload` (or View → Reload Config). Trigger a background-pane notification.
Expected: no banner. Set `enabled = true`, reload, trigger again → banner returns.

- [ ] **Step 7: Eager authorization (clean state)**

This is best observed on a machine that has not yet granted Mistty notification permission. With `[notifications] enabled = true` explicitly in the config, launch the app.
Expected: the macOS permission prompt appears at launch. With no `[notifications]` table, the prompt instead appears on the first notification.

---

## Self-Review

**Spec coverage:**

- OSC 9 + OSC 777 → notification: Tasks 3 + 6. ✅
- Global `NotificationService`, single-flighted: Task 6. ✅
- Action callback re-broadcast, synchronous C-string conversion: Task 3. ✅
- `isUserViewingTab` check, no-op when viewing: Tasks 5 + 6. ✅
- Tab flag + Dock badge reuse, `updateDockBadge` extraction: Tasks 2 + 6. ✅
- `willPresent` forces banner; `didReceive` click-to-focus: Task 6. ✅
- Title resolution fallback chain: Tasks 4 + 6. ✅
- `threadIdentifier` = session id: Task 6 (`postBanner`). ✅
- `[notifications]` config, `enabled` + `explicitlyEnabled`, live reload: Task 1 + Task 6 (reads `MisttyConfig.current`). ✅
- Authorization: eager when explicit, lazy otherwise, once per process: Task 6. ✅
- Unresolvable-pane edge case (banner, no flag, no click target): Task 6 (`handleDesktopNotification` skips the `if let` block). ✅
- Permission-denied degradation: inherent — `add()` no-ops; tab flag/badge run before `add()`. ✅
- `docs/config-example.toml` + PLAN.md: Task 7. ✅
- Tests — `NotificationsConfig` parsing (incl. round-trip), title fallback, viewing-tab boolean: Tasks 1, 4, 5. ✅
- OSC 99 out of scope, recorded as follow-up: Task 7. ✅

**Placeholder scan:** none — every code step has complete code.

**Type consistency:** `NotificationsConfig(enabled:explicitlyEnabled:)` — memberwise init used in Task 1 tests matches the struct in Task 1 Step 3. `resolveNotificationTitle(rawTitle:processTitle:sessionLabel:)` and `isUserViewingTab(appActive:windowActive:sessionActive:tabActive:)` signatures match between their definition tasks (4, 5) and their use in Task 6. `.ghosttyDesktopNotification` defined in Task 3, observed in Task 6. `WindowsStore.updateDockBadge()` defined in Task 2, called in Task 6. `windowsStore.pane(byId:)` returns `(window, session, tab, pane)` — used consistently.
