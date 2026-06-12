# Audit Fixes Wave 1: Correctness & Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the five verified bugs from the 2026-06 codebase audit (pane-move shell-kill regression, surface leak on tab/session/window close, TOML config corruption, OSC-52 clipboard leak, C-callback use-after-free) plus four security hardening items (socket peer check, socket/dir/frecency permissions, notification text cap).

**Architecture:** All changes are small, local diffs to existing files. The one structural change: `MisttyTab` gains `detachPane(_:)` (remove without surface teardown, for pane moves) and `closePane(_:)` becomes detach + release. `MisttySession`/`MisttyTab` gain cascade-teardown helpers called from `closeTab`/`closeSession`/`closeWindow`.

**Tech Stack:** Swift / SwiftPM. Tests: XCTest via `swift test`. The app embeds libghostty (prebuilt GhosttyKit.xcframework); tests use `TerminalSurfaceView.skipSurfaceCreation = true` to avoid spawning real surfaces.

**Verification commands:**
- Full test suite: `swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log` (then grep the log; don't re-run)
- Single test class: `swift test --skip Benchmark --filter <ClassName> 2>&1 | tee /tmp/mistty-test.log`
- Build only: `swift build 2>&1 | tee /tmp/mistty-build.log`

**Background context (audit findings):**
- `MisttyPane.releaseResources()` (Mistty/Models/MisttyPane.swift:126) eagerly frees the libghostty surface (renderer/IO threads, IOSurfaces, shell process). It exists because SwiftUI's view-tree cache keeps panes alive past close — `deinit` is unreliable here (see the "9GB / 17 days" comment trail from commit b406c48).
- `closePane` calls it, but `closeTab`/`closeSession`/`closeWindow` do not → every tab/session/window close leaks live surfaces.
- Conversely, window-mode join/break (ContentView.swift:972, :988) call `closePane` to *move* a pane — so the move kills the running shell (regression: join/break commit b01f1b8 predates leak-fix commit b406c48).

---

### Task 1: `detachPane` — stop killing the shell when a pane is moved

**Files:**
- Modify: `Mistty/Models/MisttyTab.swift:116-140` (split `closePane` into `detachPane` + release)
- Modify: `Mistty/App/ContentView.swift:972` and `:988` (join/break use `detachPane`)
- Test: `MisttyTests/Models/MisttyTabTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `MisttyTests/Models/MisttyTabTests.swift` (inside the class, after `test_closePane_releasesPaneSurface`):

```swift
  /// Window-mode join/break MOVE a pane between tabs. The move must not
  /// tear down the pane's surface — releasing it kills the running shell
  /// and silently respawns a fresh one. Regression: join/break (b01f1b8)
  /// predate the closePane teardown (b406c48), which made every pane move
  /// destroy the moved pane's process.
  func test_detachPane_keepsSurfaceAlive() {
    TerminalSurfaceView.skipSurfaceCreation = true
    defer { TerminalSurfaceView.skipSurfaceCreation = false }

    let tab = makeTab()
    tab.splitActivePane(direction: .horizontal)
    let moving = tab.panes[1]
    _ = moving.surfaceView  // force load
    XCTAssertNotNil(moving.surfaceViewIfLoaded, "precondition: view loaded")

    tab.detachPane(moving)

    XCTAssertEqual(tab.panes.count, 1)
    XCTAssertFalse(tab.layout.leafIDs.contains(moving.id))
    XCTAssertNotNil(
      moving.surfaceViewIfLoaded,
      "detachPane must keep the moved pane's surface alive — join/break"
        + " re-attach the pane to another tab")
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --skip Benchmark --filter MisttyTabTests 2>&1 | tee /tmp/mistty-test.log`
Expected: compile FAILURE — `value of type 'MisttyTab' has no member 'detachPane'`

- [ ] **Step 3: Implement `detachPane` and make `closePane` delegate to it**

In `Mistty/Models/MisttyTab.swift`, replace the entire `closePane` function (lines 116-140) with:

```swift
  /// Remove `pane` from this tab WITHOUT tearing down its libghostty
  /// surface. For move flows (window-mode join/break) where the pane
  /// lives on in another tab — the running shell must survive the move.
  func detachPane(_ pane: MisttyPane) {
    let wasActive = activePane?.id == pane.id
    let closingID = pane.id
    layout.remove(pane: pane)
    panes.removeAll { $0.id == pane.id }
    if wasActive {
      activePane = panes.last
      // The closed pane's OSC 2 title was what the tab last latched onto.
      // Replace with the new active pane's known title (or back to default).
      title = activePane?.processTitle ?? "Shell"
      // Without this, the focus ring moves to the new pane but first-responder
      // stays on the destroyed surface, so keystrokes go nowhere.
      activePane?.focusKeyboardInput()
    }
    if zoomedPane?.id == closingID { zoomedPane = nil }
  }

  func closePane(_ pane: MisttyPane) {
    detachPane(pane)
    // Force-release the libghostty surface + threads + IOSurfaces NOW.
    // SwiftUI's view-tree cache + AppKit's `_commonAwake` notification
    // observer keep the `MisttyPane` + `TerminalSurfaceView` instances
    // alive past `closePane`. Without this call the heavy resources
    // accumulate — see the 9GB / 17-day scenario investigated in
    // `b406c48`. The Swift objects may still leak (small per-object
    // cost) but the multi-MB-per-pane GPU + thread resources are
    // reliably released.
    pane.releaseResources()
  }
```

In `Mistty/App/ContentView.swift`, in `joinPaneToTab` change line 972:

```swift
    sourceTab.detachPane(pane)
```

(was `sourceTab.closePane(pane)`), and in `breakPaneToTab` change line 988:

```swift
    tab.detachPane(pane)
```

(was `tab.closePane(pane)`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --skip Benchmark --filter MisttyTabTests 2>&1 | tee /tmp/mistty-test.log`
Expected: all MisttyTabTests PASS, including `test_detachPane_keepsSurfaceAlive` and the existing `test_closePane_releasesPaneSurface` (behavior of `closePane` is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/MisttyTab.swift Mistty/App/ContentView.swift MisttyTests/Models/MisttyTabTests.swift
git commit -m "fix(pane): keep surface alive when join/break moves a pane

b406c48 made closePane tear down the libghostty surface, but window-mode
join/break used closePane to *move* a pane between tabs — killing the
running shell and respawning a fresh one. Split detachPane (remove, keep
surface) from closePane (detach + release).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Release pane surfaces when a tab closes

**Files:**
- Modify: `Mistty/Models/MisttyTab.swift` (add `releaseAllPaneResources()`)
- Modify: `Mistty/Models/MisttySession.swift:85-88` (`closeTab` cascades)
- Test: Create `MisttyTests/Models/SessionCloseTeardownTests.swift`

**Safety note for the implementer:** all `closeTab` call sites were audited. The pane-move flows (ContentView.swift:973, :989) only call `closeTab` when `panes.isEmpty` (the moved pane is already detached), and the restore paths (WindowsStore+Snapshot.swift:76, WindowsStore.swift:203) close a freshly-created default tab whose pane never materialized a surface (`releaseResources` is an idempotent no-op then). So cascading teardown in `closeTab` is safe everywhere.

- [ ] **Step 1: Write the failing test**

Create `MisttyTests/Models/SessionCloseTeardownTests.swift`:

```swift
import XCTest

@testable import Mistty

/// Regression tests for the surface-teardown gap found in the 2026-06
/// audit: `closePane` released surfaces but `closeTab` / `closeSession` /
/// `closeWindow` did not, leaking renderer threads + IOSurfaces + shell
/// processes on every tab/session/window close (same class as b406c48).
@MainActor
final class SessionCloseTeardownTests: XCTestCase {
  private var windowsStore: WindowsStore!
  private var state: WindowState!

  override func setUp() async throws {
    await MainActor.run {
      TerminalSurfaceView.skipSurfaceCreation = true
      windowsStore = WindowsStore()
      state = windowsStore.createWindow()
    }
  }

  override func tearDown() async throws {
    await MainActor.run {
      TerminalSurfaceView.skipSurfaceCreation = false
      state = nil
      windowsStore = nil
    }
  }

  private func makeSession() -> MisttySession {
    state.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  }

  func test_closeTab_releasesAllPaneSurfaces() {
    let session = makeSession()
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    let panes = tab.panes
    panes.forEach { _ = $0.surfaceView }  // force load
    XCTAssertTrue(
      panes.allSatisfy { $0.surfaceViewIfLoaded != nil }, "precondition: views loaded")

    session.closeTab(tab)

    for pane in panes {
      XCTAssertNil(
        pane.surfaceViewIfLoaded,
        "closeTab must release every contained pane's surface")
    }
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --skip Benchmark --filter SessionCloseTeardownTests 2>&1 | tee /tmp/mistty-test.log`
Expected: FAIL — `test_closeTab_releasesAllPaneSurfaces` asserts nil but `surfaceViewIfLoaded` is still set.

- [ ] **Step 3: Implement the cascade**

In `Mistty/Models/MisttyTab.swift`, add after `closePane`:

```swift
  /// Release every pane's libghostty surface. Called when the whole tab
  /// is discarded (session.closeTab, session/window teardown) —
  /// `closePane` handles the single-pane case. Idempotent; panes whose
  /// surface never materialized are no-ops.
  func releaseAllPaneResources() {
    for pane in panes { pane.releaseResources() }
  }
```

In `Mistty/Models/MisttySession.swift`, replace `closeTab` (lines 85-88) with:

```swift
  func closeTab(_ tab: MisttyTab) {
    tabs.removeAll { $0.id == tab.id }
    if activeTab?.id == tab.id { activeTab = tabs.last }
    // Pane-move flows (join/break) detach the pane and only close the tab
    // once it's empty, so this only tears down surfaces that are genuinely
    // going away. See MisttyTab.closePane for why eager release is needed.
    tab.releaseAllPaneResources()
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --skip Benchmark --filter "SessionCloseTeardownTests|MisttyTabTests" 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS (both classes).

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/MisttyTab.swift Mistty/Models/MisttySession.swift MisttyTests/Models/SessionCloseTeardownTests.swift
git commit -m "fix(tab): release all pane surfaces on closeTab

closePane released the closed pane's surface but closing a whole tab
(Cmd+Shift+W, tab-bar close button, IPC closeTab) skipped teardown,
leaking renderer threads, IOSurfaces and shell processes per pane.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Release surfaces when a session closes (tabs + popups)

**Files:**
- Modify: `Mistty/Models/MisttySession.swift` (add `releaseAllResources()`)
- Modify: `Mistty/Models/WindowState.swift:50-53` (`closeSession` cascades)
- Test: `MisttyTests/Models/SessionCloseTeardownTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `SessionCloseTeardownTests`:

```swift
  func test_closeSession_releasesTabPanesAndPopupPanes() {
    let session = makeSession()
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    session.togglePopup(definition: PopupDefinition(name: "scratch", command: "top"))
    let panes = tab.panes
    let popupPane = session.popups[0].pane
    (panes + [popupPane]).forEach { _ = $0.surfaceView }  // force load

    state.closeSession(session)

    for pane in panes + [popupPane] {
      XCTAssertNil(
        pane.surfaceViewIfLoaded,
        "closeSession must release every tab pane and popup pane surface")
    }
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --skip Benchmark --filter SessionCloseTeardownTests 2>&1 | tee /tmp/mistty-test.log`
Expected: FAIL — popup pane (and tab panes) still loaded after `closeSession`.

- [ ] **Step 3: Implement**

In `Mistty/Models/MisttySession.swift`, add after `closePopup` (line 184):

```swift
  /// Tear down every libghostty surface owned by this session — all tabs'
  /// panes and all popup panes. Called when the session (or its window)
  /// is discarded. See `MisttyTab.closePane` for why eager release is
  /// required (SwiftUI cache retention; b406c48). Idempotent.
  func releaseAllResources() {
    for tab in tabs { tab.releaseAllPaneResources() }
    for popup in popups { popup.pane.releaseResources() }
  }
```

In `Mistty/Models/WindowState.swift`, replace `closeSession` (lines 50-53) with:

```swift
  func closeSession(_ session: MisttySession) {
    sessions.removeAll { $0.id == session.id }
    if activeSession?.id == session.id { activeSession = sessions.last }
    session.releaseAllResources()
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --skip Benchmark --filter SessionCloseTeardownTests 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/MisttySession.swift Mistty/Models/WindowState.swift MisttyTests/Models/SessionCloseTeardownTests.swift
git commit -m "fix(session): release all tab and popup surfaces on closeSession

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Release surfaces when a window closes (after snapshot)

**Files:**
- Modify: `Mistty/Models/WindowsStore.swift:121-170` (`closeWindow`)
- Test: `MisttyTests/Models/SessionCloseTeardownTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `SessionCloseTeardownTests`:

```swift
  func test_closeWindow_releasesAllSurfaces_andStillSnapshots() {
    let session = makeSession()
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    let panes = tab.panes
    panes.forEach { _ = $0.surfaceView }  // force load

    windowsStore.closeWindow(state)

    for pane in panes {
      XCTAssertNil(
        pane.surfaceViewIfLoaded,
        "closeWindow must cascade surface teardown through its sessions")
    }
    // The recently-closed snapshot must still be captured (teardown runs
    // AFTER the snapshot, which reads live pane state).
    XCTAssertNotNil(
      windowsStore.reopenMostRecentClosed(),
      "closeWindow must still push a reopenable snapshot")
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --skip Benchmark --filter SessionCloseTeardownTests 2>&1 | tee /tmp/mistty-test.log`
Expected: FAIL — panes still loaded after `closeWindow`.

- [ ] **Step 3: Implement**

In `Mistty/Models/WindowsStore.swift`, in `closeWindow`, replace the final two lines of the function (lines 168-169):

```swift
    windows.removeAll { $0.id == state.id }
    if activeWindow?.id == state.id { activeWindow = windows.last }
```

with:

```swift
    windows.removeAll { $0.id == state.id }
    if activeWindow?.id == state.id { activeWindow = windows.last }
    // Tear down all surfaces now that the snapshot has been captured —
    // snapshotLayout's foreground-process probe reads the live pty, so
    // this must stay AFTER the WindowSnapshot construction above.
    for session in state.sessions { session.releaseAllResources() }
```

(The empty-window early-return path above it has no sessions, so it needs no teardown.)

- [ ] **Step 4: Run the full suite**

Run: `swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS. Pay attention to `WindowsStoreSnapshotTests` and `WorkspaceSnapshotTests` — restore() calls closeWindow internally and must still work.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/WindowsStore.swift MisttyTests/Models/SessionCloseTeardownTests.swift
git commit -m "fix(window): release all session surfaces on closeWindow

Completes the teardown cascade: closeWindow (Cmd+Shift+W on last
session, red traffic light, restore() clearing old windows) now frees
every surface after capturing the recently-closed snapshot.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: TOML-escape popup name/command in `MisttyConfig.save()`

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift:510-511`
- Test: `MisttyTests/Config/MisttyConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `MisttyTests/Config/MisttyConfigTests.swift` (next to `test_save_restoreCommand_roundTrip`, line ~205):

```swift
  /// popup.name / popup.command were interpolated into config.toml WITHOUT
  /// tomlEscape (unlike every sibling field) — a command containing a
  /// double quote (e.g. `sh -c "..."`) produced an unparseable file on the
  /// next Settings save, silently corrupting the user's config.
  func test_save_popupWithQuotesAndBackslashes_roundTrips() throws {
    var config = MisttyConfig()
    config.popups = [
      PopupDefinition(
        name: #"log "viewer""#,
        command: #"sh -c "tail -f /tmp/a.log | grep \"error\"""#)
    ]
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-popup-escape-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.popups, config.popups)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --skip Benchmark --filter MisttyConfigTests 2>&1 | tee /tmp/mistty-test.log`
Expected: FAIL — `loadThrowing` throws a TOML parse error (unescaped quote breaks the file).

- [ ] **Step 3: Fix the two lines**

In `Mistty/Config/MisttyConfig.swift`, replace lines 510-511:

```swift
      lines.append("name = \"\(popup.name)\"")
      lines.append("command = \"\(popup.command)\"")
```

with:

```swift
      lines.append("name = \"\(tomlEscape(popup.name))\"")
      lines.append("command = \"\(tomlEscape(popup.command))\"")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --skip Benchmark --filter MisttyConfigTests 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS (all config tests).

- [ ] **Step 5: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift MisttyTests/Config/MisttyConfigTests.swift
git commit -m "fix(config): toml-escape popup name/command on save

A popup command containing a quote or backslash produced an unparseable
config.toml on the next Settings save.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Deny OSC-52 clipboard reads (silent clipboard exfiltration)

**Files:**
- Modify: `Mistty/App/GhosttyApp.swift:161-172` (`confirmReadClipboardCallback`)

**Background:** `readClipboardCallback` completes reads with `confirmed: false`, which lets ghostty core route the request through `confirm_read_clipboard_cb` when confirmation is needed (default `clipboard-read = ask` ⇒ ALL program-initiated OSC-52 reads, plus unsafe paste contents). The current callback auto-confirms everything, so any program in a pane can silently read the user's clipboard. Ghostty's own deny path (vendor/ghostty/macos/Sources/Features/Terminal/BaseTerminalController.swift:1125-1136, `.cancel` case) completes the request with an **empty string and `confirmed: true`** — that's how the core frees the request state on denial. No unit test is feasible (C callback into libghostty); verification is build + optional manual check.

- [ ] **Step 1: Replace the callback**

In `Mistty/App/GhosttyApp.swift`, replace lines 161-172 (the doc comment and `confirmReadClipboardCallback`) with:

```swift
/// Clipboard confirm-read callback — ghostty routes a clipboard read here
/// when it needs confirmation: unsafe paste contents, or any OSC-52 read
/// (the default `clipboard-read = ask`). Cmd+V pastes are user-initiated,
/// so they auto-confirm (no prompt UI yet). OSC-52 reads are
/// program-initiated: auto-confirming them hands the user's clipboard
/// (passwords, tokens) to whatever runs in the pane, silently — so they
/// are denied. Denial completes the request with an empty string +
/// confirmed=true, matching ghostty's own cancel path
/// (BaseTerminalController.clipboardConfirmationComplete), which frees
/// the core's request state.
private let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = {
  userdata, str, state, request in
  guard let userdata, let state, let str else { return }
  let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  guard let surface = view.surface else { return }
  switch request {
  case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
    ghostty_surface_complete_clipboard_request(surface, str, state, true)
  default:
    // OSC-52 read (and any future program-initiated request): deny.
    ghostty_surface_complete_clipboard_request(surface, "", state, true)
  }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log`
Expected: build succeeds. (If the switch over the C enum complains about exhaustiveness, the `default` case covers it; do NOT add `@unknown default` — this is an imported C enum, not a frozen Swift enum.)

- [ ] **Step 3: Manual verification (optional, requires running app)**

In a Mistty pane: `printf '\033]52;c;?\007'` — previously this silently returned the clipboard to the shell; now the program receives an empty reply. Cmd+V paste must still work, including pasting text that contains control characters (that's the PASTE-with-confirmation path).

- [ ] **Step 4: Commit**

```bash
git add Mistty/App/GhosttyApp.swift
git commit -m "fix(security): deny OSC-52 clipboard reads

confirmReadClipboardCallback auto-confirmed every clipboard read,
letting any program in a pane silently exfiltrate the macOS clipboard
via OSC-52. Cmd+V (PASTE request) still auto-confirms; program-initiated
reads are denied with an empty completion, matching ghostty's cancel
path so the core request state is freed.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Fix use-after-free window in ghostty action callbacks

**Files:**
- Modify: `Mistty/App/GhosttyApp.swift:28-101, 118-136, 186-196` (five action cases + `closeSurfaceCallback`)

**Background:** libghostty invokes these callbacks on background threads. The current code captures the raw `surface` pointer into `DispatchQueue.main.async` blocks and calls `ghostty_surface_userdata(surface)` *inside* the block — but the main thread can run `tearDownSurface → ghostty_surface_free` before the block executes (close-pane race), making that call a heap use-after-free. Fix: resolve userdata synchronously (the surface is valid for the duration of the callback), `retain()` the Swift view across the hop, and never touch the C surface pointer after the callback returns. The same dangling-reference risk applies to `closeSurfaceCallback`'s unretained `view` capture. Build-verified (no unit test possible for C callback timing).

- [ ] **Step 1: Rewrite the five action cases**

In `Mistty/App/GhosttyApp.swift`, replace the `GHOSTTY_ACTION_SET_TITLE` case (lines 28-44) with:

```swift
  case GHOSTTY_ACTION_SET_TITLE:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      if let title = action.action.set_title.title {
        let titleStr = String(cString: title)
        // Resolve userdata NOW — `surface` is only guaranteed valid for
        // the duration of this callback. The main thread can free it
        // (tearDownSurface) before the async block runs, which made the
        // deferred ghostty_surface_userdata call a use-after-free. The
        // retain keeps the Swift view alive across the hop; the C
        // surface pointer is never touched after this callback returns.
        guard let userdata = ghostty_surface_userdata(surface) else { return true }
        let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
        DispatchQueue.main.async {
          let view = unmanagedView.takeRetainedValue()
          NotificationCenter.default.post(
            name: .ghosttySetTitle,
            object: nil,
            userInfo: ["paneID": view.pane?.id as Any, "title": titleStr]
          )
        }
      }
    }
    return true
```

Replace the `GHOSTTY_ACTION_RING_BELL` case (lines 56-69) with:

```swift
  case GHOSTTY_ACTION_RING_BELL:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      // See GHOSTTY_ACTION_SET_TITLE for the userdata-resolution rationale.
      guard let userdata = ghostty_surface_userdata(surface) else { return true }
      let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
      DispatchQueue.main.async {
        let view = unmanagedView.takeRetainedValue()
        NotificationCenter.default.post(
          name: .ghosttyRingBell,
          object: nil,
          userInfo: ["paneID": view.pane?.id as Any]
        )
      }
    }
    return true
```

Replace the `GHOSTTY_ACTION_PWD` case (lines 71-87) with:

```swift
  case GHOSTTY_ACTION_PWD:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      if let pwd = action.action.pwd.pwd {
        let pwdStr = String(cString: pwd)
        // See GHOSTTY_ACTION_SET_TITLE for the userdata-resolution rationale.
        guard let userdata = ghostty_surface_userdata(surface) else { return true }
        let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
        DispatchQueue.main.async {
          let view = unmanagedView.takeRetainedValue()
          NotificationCenter.default.post(
            name: .ghosttyPwd,
            object: nil,
            userInfo: ["paneID": view.pane?.id as Any, "pwd": pwdStr]
          )
        }
      }
    }
    return true
```

Replace the `GHOSTTY_ACTION_SCROLLBAR` case (lines 89-101) with:

```swift
  case GHOSTTY_ACTION_SCROLLBAR:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      let sb = action.action.scrollbar
      // See GHOSTTY_ACTION_SET_TITLE for the userdata-resolution rationale.
      guard let userdata = ghostty_surface_userdata(surface) else { return true }
      let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
      DispatchQueue.main.async {
        let view = unmanagedView.takeRetainedValue()
        view.scrollbarState = ScrollbarState(total: sb.total, offset: sb.offset, len: sb.len)
        // If copy mode is hinting, re-scan labels after mouse/wheel scroll.
        NotificationCenter.default.post(name: .misttyScrollChanged, object: nil)
      }
    }
    return true
```

Replace the `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` case (lines 118-136) with:

```swift
  case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      let notification = action.action.desktop_notification
      // Convert the C strings synchronously — `action` is only valid for the
      // duration of this callback.
      let title = notification.title.map { String(cString: $0) } ?? ""
      let body = notification.body.map { String(cString: $0) } ?? ""
      // See GHOSTTY_ACTION_SET_TITLE for the userdata-resolution rationale.
      guard let userdata = ghostty_surface_userdata(surface) else { return true }
      let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
      DispatchQueue.main.async {
        let view = unmanagedView.takeRetainedValue()
        NotificationCenter.default.post(
          name: .ghosttyDesktopNotification,
          object: nil,
          userInfo: ["paneID": view.pane?.id as Any, "title": title, "body": body]
        )
      }
    }
    return true
```

- [ ] **Step 2: Fix `closeSurfaceCallback`**

Replace `closeSurfaceCallback` (lines 185-196) with:

```swift
/// Close surface callback — shell exited. Retain the view across the
/// main-thread hop; the unretained reference could dangle if the pane is
/// torn down (and the view deallocated) before the block runs.
private let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { userdata, processAlive in
  guard let userdata else { return }
  let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
  DispatchQueue.main.async {
    let view = unmanagedView.takeRetainedValue()
    NotificationCenter.default.post(
      name: .ghosttyCloseSurface,
      object: nil,
      userInfo: ["paneID": view.pane?.id as Any]
    )
  }
}
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log`
Expected: build + all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Mistty/App/GhosttyApp.swift
git commit -m "fix(ghostty): resolve surface userdata before main-thread hop

Action callbacks captured the raw ghostty surface pointer into
DispatchQueue.main.async blocks and called ghostty_surface_userdata
inside them — a use-after-free if the main thread freed the surface
(close-pane) before the block ran. Resolve userdata synchronously while
the surface is guaranteed valid and retain the Swift view across the
hop instead.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Harden the IPC socket (peer uid check + explicit permissions)

**Files:**
- Modify: `Mistty/Services/IPCListener.swift:24-77` (`start`), `:93-122` (`acceptLoop`)

**Background:** The socket grants keystroke injection (`sendKeys` = code execution) and screen reads (`getText`) to anyone who can connect. Today the only gate is the parent directory's 0700 — applied solely when the directory is first created; the socket file itself inherits umask. Add three independent layers. Build-verified + manual CLI smoke test (the listener binds a fixed path; no unit-test seam — do not add one in this task).

- [ ] **Step 1: Assert directory + socket file permissions in `start()`**

In `Mistty/Services/IPCListener.swift`, in `start()`, replace lines 27-30:

```swift
    // Ensure parent directory exists with 0700 permissions
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
```

with:

```swift
    // Ensure parent directory exists with 0700 permissions. createDirectory
    // only applies the attributes when it creates the directory, so also
    // re-assert 0700 on every start — a perms drift on an existing dir
    // would otherwise silently expose the socket (which grants keystroke
    // injection and screen reads to anyone who can connect).
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: dir)
```

Then, directly after the successful `bind` guard (after line 58, before the `// Listen` section), add:

```swift
    // The socket file's mode is umask-dependent after bind (usually
    // world-connectable if the parent dir were ever traversable). Clamp it
    // to owner-only as a second layer behind the directory perms.
    chmod(path, 0o600)
```

- [ ] **Step 2: Reject foreign-uid peers in `acceptLoop`**

In `acceptLoop`, after the `guard clientFD >= 0` block (line 106) and before the `SO_NOSIGPIPE` setsockopt, add:

```swift
      // Belt-and-braces peer check: only same-uid clients. Filesystem
      // perms are the primary gate, but they're a single layer — this
      // keeps the socket closed to other local users even if directory
      // permissions drift.
      var peerUID: uid_t = 0
      var peerGID: gid_t = 0
      guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == getuid() else {
        Darwin.close(clientFD)
        continue
      }
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log`
Expected: build + all tests PASS.

- [ ] **Step 4: Manual verification (optional, requires running app)**

With the app running: `mistty session list` still works, and `ls -l ~/Library/Application\ Support/Mistty/` shows the socket as `srw-------` and the directory as `drwx------`.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/IPCListener.swift
git commit -m "fix(security): harden IPC socket with peer-uid check and explicit perms

The socket grants keystroke injection and screen reads to any process
that can connect; the only gate was the parent dir's 0700, applied only
at creation. Now: re-assert dir 0700 on every start, chmod the socket
file 0600 after bind, and reject peers whose uid differs (getpeereid).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Create the frecency directory with 0700

**Files:**
- Modify: `Mistty/Services/FrecencyService.swift:18-25` (`defaultStorageURL`)

- [ ] **Step 1: Add the permissions attribute**

In `Mistty/Services/FrecencyService.swift`, in `defaultStorageURL()`, replace:

```swift
    let dir = appSupport.appendingPathComponent("com.mistty")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
```

with:

```swift
    let dir = appSupport.appendingPathComponent("com.mistty")
    // 0700 to match the IPC dir — frecency.json is a history of visited
    // directory paths, a mild privacy signal that shouldn't rely solely on
    // the Application Support parent being user-only.
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
```

- [ ] **Step 2: Build and run the frecency tests**

Run: `swift test --skip Benchmark --filter FrecencyServiceTests 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Mistty/Services/FrecencyService.swift
git commit -m "fix(security): create frecency dir with 0700 perms

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Cap program-controlled notification text

**Files:**
- Modify: `Mistty/Services/NotificationService.swift` (add `clampNotificationText`, use in `postBanner`)
- Test: `MisttyTests/Services/NotificationServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `MisttyTests/Services/NotificationServiceTests.swift` (it already tests the free functions `resolveNotificationTitle` / `isUserViewingTab`; follow the same style):

```swift
  func test_clampNotificationText_passesShortTextThrough() {
    XCTAssertEqual(clampNotificationText("build done"), "build done")
  }

  func test_clampNotificationText_capsLongText() {
    let long = String(repeating: "x", count: 10_000)
    XCTAssertEqual(clampNotificationText(long).count, 256)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --skip Benchmark --filter NotificationServiceTests 2>&1 | tee /tmp/mistty-test.log`
Expected: compile FAILURE — `cannot find 'clampNotificationText' in scope`.

- [ ] **Step 3: Implement**

In `Mistty/Services/NotificationService.swift`, add after `isUserViewingTab` (line 32):

```swift
/// Cap program-controlled notification text. OSC 9 title/body come straight
/// from whatever runs in the pane; unbounded strings cost memory in the
/// notification store and make spoofing/spam cheap. 256 chars is far beyond
/// what a macOS banner can display.
func clampNotificationText(_ text: String, limit: Int = 256) -> String {
  text.count <= limit ? text : String(text.prefix(limit))
}
```

In `postBanner` (line 119), replace:

```swift
    content.title = title
    content.body = body
```

with:

```swift
    content.title = clampNotificationText(title)
    content.body = clampNotificationText(body)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --skip Benchmark --filter NotificationServiceTests 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/NotificationService.swift MisttyTests/Services/NotificationServiceTests.swift
git commit -m "fix(notifications): cap OSC 9 title/body length

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Final verification

- [ ] Run the complete suite once more: `swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log` — all PASS, no skips beyond Benchmark.
- [ ] `git log --oneline main..HEAD` (or last 10 commits) shows one commit per task with the messages above.

## Deferred to follow-up plans

- **Wave 2 (performance):** copy-mode search caching, overlay viewport snapshots, `isInRemoteShell` TTL cache, restorable-state debounce, scrollbar-event coalescing, DebugLog file handle, HintDetector trimming, scroll-multiplier caching.
- **Wave 3 (mechanical dedups):** CLI `runIPC` helper, IPCService `withTab/withSession` helpers, menu table from `ShortcutAction`, socket I/O into `MisttyShared/UnixSocket`, ghostty read-text helper on `TerminalSurfaceView`, `WindowsStore` snapshot/restore dedup, `withOptionalCString`, dead-code removal.
- **Wave 4 (architecture):** `CopyModeController` extraction + typed surface API, notification-bus → typed command router, IPC request envelope with structured errors, `ConfigStore`.
