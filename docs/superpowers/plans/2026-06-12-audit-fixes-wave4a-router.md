# Audit Fixes Wave 4a-Router: Typed Window-Command Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill the per-window notification fan-out bug class: today ~26 `mistty*` notifications are delivered to EVERY window's ContentView, each handler re-remembering the `guard windowsStore.isActiveTerminalWindow(state:)` check (~25 repetitions; comments at ContentView.swift:112-155 document three bugs this caused). Replace delivery with a typed `WindowCommand` enum and a router that resolves the target window ONCE.

**Architecture — "typed delivery, legacy ingress":** Entry points (menu `menuButton`s, `ShortcutMonitor`) keep posting NotificationCenter exactly as today. The router subscribes to those legacy notifications ONCE, converts each to a `WindowCommand`, resolves the single active terminal window, and invokes that window's registered handler. ContentView's ~26 `.onReceive`+guard blocks collapse into one `register/unregister` + one `switch`. NOT in scope (stay as-is): `ghostty*` events (pane-targeted, resolved by paneID), `misttyConfigDidReload` + `misttyScrollChanged` (genuine broadcasts), `misttyReloadConfig`/`misttyReopenClosedWindow` (single app-level receiver in MisttyApp), `misttyCloseWindow`/`misttyToggleSidebar` (WindowRootView, separate receiver per window root — leave for a later pass), `NSApplication.didBecome/didResignActive`.

**Tech Stack:** Swift/SwiftPM, XCTest. Baseline: 23 ChromePolish failures expected; anything else is a regression.

---

### Task 1: `WindowCommand` + `WindowCommandRouter` (TDD)

**Files:**
- Create: `Mistty/App/WindowCommand.swift`
- Test: Create `MisttyTests/App/WindowCommandRouterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest

@testable import Mistty

@MainActor
final class WindowCommandRouterTests: XCTestCase {
  func test_dispatch_reachesOnlyActiveWindowHandler() {
    let store = WindowsStore()
    let w1 = store.createWindow()
    let w2 = store.createWindow()
    store.activeWindow = w2
    let router = WindowCommandRouter(windowsStore: store)

    var w1Got: [WindowCommand] = []
    var w2Got: [WindowCommand] = []
    router.register(windowID: w1.id) { w1Got.append($0) }
    router.register(windowID: w2.id) { w2Got.append($0) }

    router.dispatch(.nextTab)

    XCTAssertEqual(w1Got, [])
    XCTAssertEqual(w2Got, [.nextTab])
  }

  func test_dispatch_afterUnregister_isNoOp() {
    let store = WindowsStore()
    let w = store.createWindow()
    store.activeWindow = w
    let router = WindowCommandRouter(windowsStore: store)
    var got: [WindowCommand] = []
    router.register(windowID: w.id) { got.append($0) }
    router.unregister(windowID: w.id)
    router.dispatch(.closePane)
    XCTAssertEqual(got, [])
  }

  func test_legacyNotification_isBridgedToTypedCommand() {
    let store = WindowsStore()
    let w = store.createWindow()
    store.activeWindow = w
    let router = WindowCommandRouter(windowsStore: store)
    var got: [WindowCommand] = []
    router.register(windowID: w.id) { got.append($0) }

    NotificationCenter.default.post(name: .misttyFocusTabByIndex, object: nil,
                                    userInfo: ["index": 3])
    NotificationCenter.default.post(name: .misttyYankHintsOpen, object: nil)

    XCTAssertEqual(got, [.focusTab(index: 3), .yankHints(action: .open)])
  }
}
```

**Targeting note:** the old per-window guard was `windowsStore.isActiveTerminalWindow(state:)`. The router must use the SAME predicate to pick the target (`windows.first { isActiveTerminalWindow(state: $0) }`) so semantics are identical — read that method first; if it consults NSWindow key state, the no-NSWindow test environment must still work for these tests (check how existing tests handle `isActiveTerminalWindow`, e.g. IPCServiceTests; if it returns false without real NSWindows, have the router fall back to `windowsStore.activeWindow` when no window passes the key-state predicate, and assert THAT documented order in the tests).

- [ ] **Step 2: Red run** (compile failure: `cannot find 'WindowCommandRouter'`)

- [ ] **Step 3: Implement `Mistty/App/WindowCommand.swift`**

```swift
import AppKit
import Foundation

/// Per-window commands that used to be NotificationCenter broadcasts
/// delivered to EVERY window's ContentView (each handler repeating the
/// active-window guard — the fan-out caused at least three documented
/// bugs; see the bell-badge/popup-focus/shift-state comments that lived
/// at the top of ContentView).
enum WindowCommand: Equatable {
  case newTab(plain: Bool)
  case splitHorizontal(plain: Bool)
  case splitVertical(plain: Bool)
  case sessionManager
  case closePane
  case closeTab
  case renameTab
  case renameSession
  case reparentSession(directory: String?)
  case windowMode
  case copyMode
  case yankHints(action: HintAction)
  case togglePopup(name: String)
  case focusTab(index: Int)
  case focusSession(index: Int)
  case nextTab
  case prevTab
  case nextSession
  case prevSession
  case moveSessionUp
  case moveSessionDown
  case toggleTabBar
}

/// Resolves the single target window ONCE and delivers typed commands to
/// its registered handler. Ingress stays legacy: the router bridges the
/// existing mistty* notifications (menu items and ShortcutMonitor keep
/// posting them) into typed dispatches — entry points can migrate to
/// direct dispatch() calls later without touching delivery again.
@MainActor
final class WindowCommandRouter {
  private let windowsStore: WindowsStore
  private var handlers: [Int: (WindowCommand) -> Void] = [:]
  private var observers: [NSObjectProtocol] = []

  init(windowsStore: WindowsStore) {
    self.windowsStore = windowsStore
    bridgeLegacyNotifications()
  }

  deinit {
    // NotificationCenter blocks hold no strong self (weak captures below),
    // but remove them explicitly for determinism.
    for token in observers { NotificationCenter.default.removeObserver(token) }
  }

  func register(windowID: Int, handler: @escaping (WindowCommand) -> Void) {
    handlers[windowID] = handler
  }

  func unregister(windowID: Int) {
    handlers[windowID] = nil
  }

  func dispatch(_ command: WindowCommand) {
    guard let target = targetWindow() else { return }
    handlers[target.id]?(command)
  }

  /// Same predicate the per-window guards used, applied once. Falls back
  /// to the store's activeWindow when no window passes the key-state
  /// check (e.g. headless tests).
  private func targetWindow() -> WindowState? {
    windowsStore.windows.first { windowsStore.isActiveTerminalWindow(state: $0) }
      ?? windowsStore.activeWindow
  }

  private func bridge(_ name: Notification.Name, _ make: @escaping (Notification) -> WindowCommand?) {
    let token = NotificationCenter.default.addObserver(
      forName: name, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated {
        guard let command = make(note) else { return }
        self?.dispatch(command)
      }
    }
    observers.append(token)
  }

  private func bridgeLegacyNotifications() {
    bridge(.misttyNewTab) { _ in .newTab(plain: false) }
    bridge(.misttyNewTabPlain) { _ in .newTab(plain: true) }
    bridge(.misttySplitHorizontal) { _ in .splitHorizontal(plain: false) }
    bridge(.misttySplitHorizontalPlain) { _ in .splitHorizontal(plain: true) }
    bridge(.misttySplitVertical) { _ in .splitVertical(plain: false) }
    bridge(.misttySplitVerticalPlain) { _ in .splitVertical(plain: true) }
    bridge(.misttySessionManager) { _ in .sessionManager }
    bridge(.misttyClosePane) { _ in .closePane }
    bridge(.misttyCloseTab) { _ in .closeTab }
    bridge(.misttyRenameTab) { _ in .renameTab }
    bridge(.misttyRenameSession) { _ in .renameSession }
    bridge(.misttyReparentSession) { note in
      .reparentSession(directory: note.userInfo?["directory"] as? String)
    }
    bridge(.misttyWindowMode) { _ in .windowMode }
    bridge(.misttyCopyMode) { _ in .copyMode }
    bridge(.misttyYankHints) { _ in .yankHints(action: .copy) }
    bridge(.misttyYankHintsOpen) { _ in .yankHints(action: .open) }
    bridge(.misttyYankHintsCursor) { _ in .yankHints(action: .cursor) }
    bridge(.misttyPopupToggle) { note in
      (note.userInfo?["name"] as? String).map { .togglePopup(name: $0) }
    }
    bridge(.misttyFocusTabByIndex) { note in
      (note.userInfo?["index"] as? Int).map { .focusTab(index: $0) }
    }
    bridge(.misttyFocusSessionByIndex) { note in
      (note.userInfo?["index"] as? Int).map { .focusSession(index: $0) }
    }
    bridge(.misttyNextTab) { _ in .nextTab }
    bridge(.misttyPrevTab) { _ in .prevTab }
    bridge(.misttyNextSession) { _ in .nextSession }
    bridge(.misttyPrevSession) { _ in .prevSession }
    bridge(.misttyMoveSessionUp) { _ in .moveSessionUp }
    bridge(.misttyMoveSessionDown) { _ in .moveSessionDown }
    bridge(.misttyToggleTabBar) { _ in .toggleTabBar }
  }
}
```

**Adjust to reality while implementing (read the code first, the quoted payloads are from the audit reads):** check the actual `userInfo` keys posted for `misttyReparentSession` (ContentView:254 reads `notification`), `misttyPopupToggle` ("name"), `misttyFocusTabByIndex`/`misttyFocusSessionByIndex` ("index"). The `yankHints` HintAction values (.copy/.open/.cursor) come from `handleYankHints(action:)`. If `HintAction` isn't visible from the App target file, import/move accordingly — it lives in `Mistty/Models/CopyModeAction.swift`, same target.

- [ ] **Step 4: Green run** of WindowCommandRouterTests.

- [ ] **Step 5: Commit** — `feat(router): typed WindowCommand router with legacy notification bridge` (+ Co-Authored-By trailer, as for all commits in this plan).

---

### Task 2: ContentView consumes the router

**Files:**
- Modify: `Mistty/App/ContentView.swift` (the ~26 mistty* `.onReceive` blocks → one registration + switch)
- Modify: `Mistty/App/MisttyApp.swift` (create the router next to the WindowsStore, inject via `.environment`)
- Modify (only if needed for injection): `Mistty/App/WindowRootView.swift`

**Hard rule:** MOVE each `.onReceive` body into the corresponding `switch` arm verbatim — do not rewrite the logic. The repeated `guard windowsStore.isActiveTerminalWindow(state: state) else { return }` lines are DELETED (the router now guarantees targeting); everything else in each body is preserved byte-for-byte.

- [ ] **Step 1: Wire the router in `MisttyApp`**

Match how `windowsStore` itself is created/injected in MisttyApp (read it first); add alongside:

```swift
  @State private var commandRouter: WindowCommandRouter
  // in init, after windowsStore exists:
  //   _commandRouter = State(initialValue: WindowCommandRouter(windowsStore: store))
  // and inject down the same path as windowsStore (e.g. .environment(commandRouter))
```

- [ ] **Step 2: Register in ContentView**

Add the environment property (matching the project's injection idiom for `windowsStore`), then in the same place the view currently sets up its lifecycle (`onAppear`/`onDisappear` — find the existing pair):

```swift
    .onAppear {
      commandRouter.register(windowID: state.id) { command in
        handleWindowCommand(command)
      }
    }
    .onDisappear {
      commandRouter.unregister(windowID: state.id)
    }
```

and add the single handler, each arm being the MOVED body of the old `.onReceive`:

```swift
  private func handleWindowCommand(_ command: WindowCommand) {
    switch command {
    case .newTab(let plain): /* moved body of .misttyNewTab / Plain */
    case .splitHorizontal(let plain): /* moved bodies */
    case .splitVertical(let plain): /* moved bodies */
    case .sessionManager: /* moved body */
    case .closePane: handleClosePane()
    case .closeTab: handleCloseTab()
    case .renameTab: /* moved body */
    case .renameSession: /* moved body */
    case .reparentSession(let directory): /* moved body of .misttyReparentSession */
    case .windowMode: handleWindowMode()
    case .copyMode: handleCopyMode()
    case .yankHints(let action): handleYankHints(action: action)
    case .togglePopup(let name): /* moved body of handlePopupToggle, taking name directly */
    case .focusTab(let index): /* moved body */
    case .focusSession(let index): /* moved body */
    case .nextTab: /* moved body */
    case .prevTab: /* moved body */
    case .nextSession: /* moved body */
    case .prevSession: /* moved body */
    case .moveSessionUp: /* moved body */
    case .moveSessionDown: /* moved body */
    case .toggleTabBar: /* moved body */
    }
  }
```

Where an old body was just a call to an existing private func (e.g. `handleCloseTab()`), the arm is that call. Where notification `userInfo` was unpacked in the body, the unpacking is already done by the bridge — the arm receives typed payloads.

- [ ] **Step 3: Delete the converted `.onReceive` blocks**

Remove ONLY the mistty* subscriptions covered by the enum. KEEP: `.ghosttySetTitle/.ghosttyRingBell/.ghosttyPwd/.ghosttyCloseSurface`, `.misttyConfigDidReload`, `.misttyScrollChanged`, `NSApplication.didBecomeActiveNotification`/`didResignActiveNotification`. If the type-checker-workaround computed vars (`contentWithNotifications`, `contentWithHintEntryNotifications` — see the comment near ContentView:185) become mergeable now that the chain shrank, merge them and delete the workaround comment; if the type-checker still chokes, leave the split and say so in your report.

Acceptance greps:
- `grep -c "isActiveTerminalWindow" Mistty/App/ContentView.swift` — should drop from ~25+ to the small handful in non-notification code paths (monitors). Report before/after counts.
- `grep -n "onReceive" Mistty/App/ContentView.swift` — only the KEEP list above remains.

- [ ] **Step 4: Full suite + behavior spot-checks**

Full suite at baseline. If the app builds and runs (`just run` or open the dev app): Cmd+T opens a tab in the ACTIVE window with two windows open; Cmd+1..9 focuses tabs; popup shortcut toggles; rename-tab sheet appears on the active window only.

- [ ] **Step 5: Commit** — `refactor(commands): route window commands through WindowCommandRouter`.

---

### Final verification
- [ ] Full suite baseline-only; WindowCommandRouterTests green; grep evidence reported.
