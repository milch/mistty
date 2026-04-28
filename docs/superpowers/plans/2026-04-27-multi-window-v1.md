# Multi-Window v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the multi-window bug by giving each terminal window its own independent sessions, tabs, and panes. After this lands, `Cmd+N` opens an empty window without touching existing windows; both windows persist across quit/relaunch; CLI read ops return a global view tagged with `window`.

**Architecture:** Split today's `SessionStore` into a global `WindowsStore` (registry of windows + global ID counters + tracked NSWindows + lookups) and a per-window `WindowState` (sessions/activeSession/per-window methods). New `WindowRootView` wraps `ContentView` inside the existing SwiftUI `WindowGroup`; each mounted window claims a `WindowState` from `WindowsStore.pendingRestoreStates` (FIFO) or creates a fresh one. `WorkspaceSnapshot` bumps to v2 with a `windows: [WindowSnapshot]` array; v1 payloads migrate transparently into a single window.

**Tech Stack:** Swift 6 / SwiftUI + AppKit (macOS 14+), Swift Testing (`@Test`), libghostty, ArgumentParser CLI.

**Spec:** `docs/superpowers/specs/2026-04-27-multi-window-v1-design.md`

---

## File Structure

### New files

| File                                                         | Role                                                                                                                                                                                                                              |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Mistty/Models/WindowsStore.swift`                           | Global registry: `windows`, ID counters, `trackedNSWindows`, lookups, `focusedWindow()`, `isActiveTerminalWindow(state:)`, `recentlyClosed`, `openWindowAction`, `pendingRestoreStates`.                                          |
| `Mistty/Models/WindowState.swift`                            | Per-window state: `sessions`, `activeSession` (with `lastActivatedAt` didSet), `createSession`, `closeSession`, `nextSession/prevSession`, `moveActiveSessionUp/Down`, `moveSessions`, `appendRestoredSession`, `activePaneInfo`. |
| `Mistty/App/WindowRootView.swift`                            | SwiftUI `WindowGroup` root: claims `pendingRestoreStates.first` or creates fresh `WindowState`; captures `Environment(\.openWindow)`; drains pending restores; hosts `ContentView`.                                               |
| `MisttyShared/Snapshot/WindowSnapshot.swift`                 | Per-window persistence DTO: `id`, `sessions`, `activeSessionID`.                                                                                                                                                                  |
| `Mistty/Models/WindowsStore+Snapshot.swift`                  | `takeSnapshot()` + `restore(from:config:)` extension on `WindowsStore`; replaces `SessionStore+Snapshot.swift`.                                                                                                                   |
| `MisttyTests/Models/WindowsStoreTests.swift`                 | Lookups, lifecycle, recently-closed, ID counters.                                                                                                                                                                                 |
| `MisttyTests/Models/WindowStateTests.swift`                  | Session management coverage relocated from `SessionStoreTests`.                                                                                                                                                                   |
| `MisttyTests/Snapshot/WorkspaceSnapshotMigrationTests.swift` | v1 → v2 migration round-trip.                                                                                                                                                                                                     |
| `MisttyTests/Services/IPCServiceWindowResolutionTests.swift` | `createSession` window resolution paths.                                                                                                                                                                                          |

### Deleted files

| File                                                   | Reason                                                                            |
| ------------------------------------------------------ | --------------------------------------------------------------------------------- |
| `Mistty/Models/SessionStore.swift`                     | Split into `WindowsStore` + `WindowState`.                                        |
| `Mistty/Models/SessionStore+Snapshot.swift`            | Replaced by `WindowsStore+Snapshot.swift`.                                        |
| `MisttyTests/Models/SessionStoreTests.swift`           | Coverage relocated to `WindowStateTests` + `WindowsStoreTests`.                   |
| `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift` | Coverage updated and relocated to `WindowsStoreSnapshotTests` (renamed in place). |

### Modified files

| File                                                                      | Change                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Mistty/App/MisttyApp.swift`                                              | `@State store: SessionStore` → `@State windowsStore: WindowsStore`; `WindowGroup { WindowRootView(...) }`; `appDelegate.store` → `appDelegate.windowsStore`. Add "Reopen Closed Window" menu item.                                                                                                                                                                            |
| `Mistty/App/ContentView.swift`                                            | `var store: SessionStore` → `var state: WindowState; var windowsStore: WindowsStore`. Replace all `store.activeSession` with `state.activeSession` etc. Add `isActiveTerminalWindow` guards to all Mistty notification handlers and NSEvent monitors. Cross-window lookups via `windowsStore.{session,tab,pane,popup}(byId:)`. Dock badge sums across `windowsStore.windows`. |
| `Mistty/App/AppDelegate.swift`                                            | `store` property → `windowsStore`; `willEncodeRestorableState` calls `windowsStore.takeSnapshot()`; `didDecodeRestorableState` calls `windowsStore.restore(...)`; override `applicationShouldTerminateAfterLastWindowClosed → false`.                                                                                                                                         |
| `Mistty/Services/StateRestorationObserver.swift`                          | Re-rooted at `windowsStore`; observation walks all windows' sessions/tabs/panes.                                                                                                                                                                                                                                                                                              |
| `Mistty/Services/IPCService.swift`                                        | Init takes `WindowsStore`; read endpoints iterate all windows; mutating endpoints use global lookups; `createSession` resolves `--window`/focused-window; `createWindow` allocates id + queues empty `WindowState` + fires `openWindowAction`. Response payloads gain `window` field.                                                                                         |
| `Mistty/Services/IPCListener.swift`                                       | `IPCListener(service:)` arg-only change reflects renamed param.                                                                                                                                                                                                                                                                                                               |
| `MisttyShared/MisttyServiceProtocol.swift`                                | `createSession` gains `windowID: Int?`.                                                                                                                                                                                                                                                                                                                                       |
| `MisttyShared/Models/SessionResponse.swift`                               | Add `window: Int` field + column.                                                                                                                                                                                                                                                                                                                                             |
| `MisttyShared/Models/TabResponse.swift`                                   | Add `window: Int` field + column.                                                                                                                                                                                                                                                                                                                                             |
| `MisttyShared/Models/PaneResponse.swift`                                  | Add `window: Int` field + column.                                                                                                                                                                                                                                                                                                                                             |
| `MisttyShared/Models/PopupResponse.swift`                                 | Add `window: Int` field + column.                                                                                                                                                                                                                                                                                                                                             |
| `MisttyShared/Snapshot/WorkspaceSnapshot.swift`                           | Bump `currentVersion` to 2; add `windows: [WindowSnapshot]`; remove top-level `sessions`/`activeSessionID` (lifted into `WindowSnapshot`). Custom decoder migrates v1 payloads.                                                                                                                                                                                               |
| `MisttyCLI/Commands/SessionCommand.swift`                                 | `Create` subcommand gains `--window <Int>?` option, forwarded in IPC payload.                                                                                                                                                                                                                                                                                                 |
| `Mistty/Views/Sidebar/SidebarView.swift`                                  | `store: SessionStore` → `state: WindowState` + `windowsStore: WindowsStore` (for global lookups if needed). Sessions list reads `state.sessions`.                                                                                                                                                                                                                             |
| `Mistty/Views/SessionManager/SessionManagerViewModel.swift`               | `init(store:)` → `init(state:windowsStore:)`. Running sessions seeded from `state.sessions`.                                                                                                                                                                                                                                                                                  |
| `MisttyTests/MisttyTests.swift` (and any other test using `SessionStore`) | Replace with `WindowsStore` + `WindowState` test helpers.                                                                                                                                                                                                                                                                                                                     |

---

## Prerequisite: work in a worktree

This change touches ~15 files across data model, SwiftUI, AppKit, IPC, and tests. Use a dedicated worktree.

- [ ] **Setup: create worktree**

```bash
cd /Users/manu/Developer/mistty
git worktree add .worktrees/multi-window-v1 -b feat/multi-window-v1
just setup-worktree .worktrees/multi-window-v1
cd .worktrees/multi-window-v1
```

Run all subsequent tasks from `.worktrees/multi-window-v1/`.

---

## Phase 1 — Build `WindowsStore` and `WindowState` alongside `SessionStore`

The new types coexist with `SessionStore` until Phase 3, when the SwiftUI rewiring switches over and the old type is deleted. This keeps the build green at every step.

### Task 1: Skeleton `WindowsStore` (TDD)

**Files:**

- Create: `Mistty/Models/WindowsStore.swift`
- Create: `MisttyTests/Models/WindowsStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MisttyTests/Models/WindowsStoreTests.swift`:

```swift
import Testing
@testable import Mistty

@MainActor
struct WindowsStoreTests {
  @Test
  func generatesGloballyUniqueIDs() {
    let store = WindowsStore()
    #expect(store.generateSessionID() == 1)
    #expect(store.generateTabID() == 1)
    #expect(store.generatePaneID() == 1)
    #expect(store.generatePopupID() == 1)
    #expect(store.generateWindowID() == 1)
    #expect(store.generateSessionID() == 2)
    #expect(store.generateWindowID() == 2)
  }

  @Test
  func reserveNextWindowIDAdvancesCounter() {
    let store = WindowsStore()
    let id = store.reserveNextWindowID()
    #expect(id == 1)
    #expect(store.generateWindowID() == 2)
  }

  @Test
  func createWindowAppendsAndAssignsID() {
    let store = WindowsStore()
    let a = store.createWindow()
    let b = store.createWindow()
    #expect(store.windows.count == 2)
    #expect(a.id == 1)
    #expect(b.id == 2)
  }

  @Test
  func closeWindowRemovesFromList() {
    let store = WindowsStore()
    let a = store.createWindow()
    _ = store.createWindow()
    store.closeWindow(a)
    #expect(store.windows.count == 1)
    #expect(store.windows.first?.id == 2)
  }

  @Test
  func advanceIDCountersJumpsPastMax() {
    let store = WindowsStore()
    store.advanceIDCounters(windowMax: 5, sessionMax: 10, tabMax: 20, paneMax: 30, popupMax: 40)
    #expect(store.generateWindowID() == 6)
    #expect(store.generateSessionID() == 11)
    #expect(store.generateTabID() == 21)
    #expect(store.generatePaneID() == 31)
    #expect(store.generatePopupID() == 41)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter WindowsStoreTests
```

Expected: build fails with "cannot find 'WindowsStore' in scope".

- [ ] **Step 3: Implement `WindowsStore` skeleton**

Create `Mistty/Models/WindowsStore.swift`:

```swift
import AppKit
import Foundation
import SwiftUI

struct TrackedWindow {
  let id: Int
  weak var window: NSWindow?
  weak var state: WindowState?
}

@Observable
@MainActor
final class WindowsStore {
  private(set) var windows: [WindowState] = []
  var activeWindow: WindowState?

  var nextWindowID = 1
  var nextSessionID = 1
  var nextTabID = 1
  var nextPaneID = 1
  var nextPopupID = 1

  private(set) var trackedNSWindows: [TrackedWindow] = []
  var pendingRestoreStates: [WindowState] = []
  var recentlyClosed: [WindowSnapshot] = []
  var openWindowAction: OpenWindowAction?

  // MARK: - ID generation

  func generateWindowID() -> Int {
    let id = nextWindowID
    nextWindowID += 1
    return id
  }

  func generateSessionID() -> Int {
    let id = nextSessionID
    nextSessionID += 1
    return id
  }

  func generateTabID() -> Int {
    let id = nextTabID
    nextTabID += 1
    return id
  }

  func generatePaneID() -> Int {
    let id = nextPaneID
    nextPaneID += 1
    return id
  }

  func generatePopupID() -> Int {
    let id = nextPopupID
    nextPopupID += 1
    return id
  }

  /// Reserve a window id without creating a `WindowState`. Used by IPC
  /// `createWindow` so we can return the id synchronously while the actual
  /// view mount happens asynchronously.
  func reserveNextWindowID() -> Int { generateWindowID() }

  /// Used during state restoration to bump every counter past the highest
  /// id observed in the snapshot, so newly-allocated ids don't collide.
  func advanceIDCounters(windowMax: Int, sessionMax: Int, tabMax: Int, paneMax: Int, popupMax: Int) {
    nextWindowID = max(nextWindowID, windowMax + 1)
    nextSessionID = max(nextSessionID, sessionMax + 1)
    nextTabID = max(nextTabID, tabMax + 1)
    nextPaneID = max(nextPaneID, paneMax + 1)
    nextPopupID = max(nextPopupID, popupMax + 1)
  }

  // MARK: - Window lifecycle

  func createWindow() -> WindowState {
    let state = WindowState(id: generateWindowID(), store: self)
    windows.append(state)
    return state
  }

  func closeWindow(_ state: WindowState) {
    windows.removeAll { $0.id == state.id }
    if activeWindow?.id == state.id { activeWindow = windows.last }
  }
}
```

(Lookup helpers, NSWindow registry, focus helpers, snapshot helpers come in later tasks. `WindowSnapshot` is defined in Task 7. `WindowState` in Task 2.)

- [ ] **Step 4: Add a placeholder `WindowSnapshot` to satisfy the compiler**

Until Task 7 wires up the real schema, add a placeholder so `WindowsStore` compiles. At the **bottom** of `Mistty/Models/WindowsStore.swift`:

```swift
// Placeholder — the real `WindowSnapshot` arrives in Phase 2 (Task 7).
// Defined here as `_PlaceholderWindowSnapshot` aliased so we can swap later.
typealias _PlaceholderWindowSnapshot = Void
```

Replace `[WindowSnapshot]` with `[_PlaceholderWindowSnapshot]` in `recentlyClosed`'s declaration *for now*; Task 19 will swap the real type back in.

Update the declaration:

```swift
var recentlyClosed: [_PlaceholderWindowSnapshot] = []
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift test --filter WindowsStoreTests
```

Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Mistty/Models/WindowsStore.swift MisttyTests/Models/WindowsStoreTests.swift
git commit -m "$(cat <<'EOF'
feat: add WindowsStore skeleton with global ID counters

First step of the multi-window v1 split. WindowsStore is the global
registry; WindowState (next task) is the per-window slice.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Skeleton `WindowState` (TDD)

**Files:**

- Create: `Mistty/Models/WindowState.swift`
- Create: `MisttyTests/Models/WindowStateTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MisttyTests/Models/WindowStateTests.swift`:

```swift
import Testing
import Foundation
@testable import Mistty

@MainActor
struct WindowStateTests {
  @Test
  func createSessionAppendsAndActivates() {
    let store = WindowsStore()
    let state = store.createWindow()
    let session = state.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    #expect(state.sessions.count == 1)
    #expect(state.sessions.first?.id == session.id)
    #expect(state.activeSession?.id == session.id)
  }

  @Test
  func closeSessionRemovesFromListAndUpdatesActive() {
    let store = WindowsStore()
    let state = store.createWindow()
    let a = state.createSession(name: "a", directory: URL(fileURLWithPath: "/tmp"))
    let b = state.createSession(name: "b", directory: URL(fileURLWithPath: "/tmp"))
    #expect(state.activeSession?.id == b.id)
    state.closeSession(b)
    #expect(state.sessions.count == 1)
    #expect(state.activeSession?.id == a.id)
  }

  @Test
  func sessionIDsAreGloballyUnique() {
    let store = WindowsStore()
    let a = store.createWindow()
    let b = store.createWindow()
    let s1 = a.createSession(name: "1", directory: URL(fileURLWithPath: "/"))
    let s2 = b.createSession(name: "2", directory: URL(fileURLWithPath: "/"))
    #expect(s1.id != s2.id)
  }

  @Test
  func nextPrevSessionWrapsCircular() {
    let store = WindowsStore()
    let state = store.createWindow()
    let a = state.createSession(name: "a", directory: URL(fileURLWithPath: "/"))
    let b = state.createSession(name: "b", directory: URL(fileURLWithPath: "/"))
    state.activeSession = a
    state.nextSession()
    #expect(state.activeSession?.id == b.id)
    state.nextSession()
    #expect(state.activeSession?.id == a.id)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter WindowStateTests
```

Expected: build fails with "cannot find 'WindowState' in scope".

- [ ] **Step 3: Implement `WindowState`**

Create `Mistty/Models/WindowState.swift`:

```swift
import AppKit
import Foundation

@Observable
@MainActor
final class WindowState {
  let id: Int
  unowned let store: WindowsStore
  private(set) var sessions: [MisttySession] = []
  var activeSession: MisttySession? {
    didSet {
      activeSession?.lastActivatedAt = Date()
    }
  }

  init(id: Int, store: WindowsStore) {
    self.id = id
    self.store = store
  }

  // MARK: - Session lifecycle

  @discardableResult
  func createSession(
    name: String, directory: URL, exec: String? = nil, customName: String? = nil
  ) -> MisttySession {
    let session = MisttySession(
      id: store.generateSessionID(),
      name: name,
      directory: directory,
      exec: exec,
      customName: customName,
      tabIDGenerator: { [weak store] in store?.generateTabID() ?? 0 },
      paneIDGenerator: { [weak store] in store?.generatePaneID() ?? 0 },
      popupIDGenerator: { [weak store] in store?.generatePopupID() ?? 0 }
    )
    sessions.append(session)
    activeSession = session
    return session
  }

  func closeSession(_ session: MisttySession) {
    sessions.removeAll { $0.id == session.id }
    if activeSession?.id == session.id { activeSession = sessions.last }
  }

  /// Append a fully-constructed `MisttySession` during restore. Bypasses
  /// `createSession`'s fresh-id + default-tab flow because the session is
  /// already hydrated from a snapshot.
  func appendRestoredSession(_ session: MisttySession) {
    sessions.append(session)
  }

  // MARK: - Navigation

  func nextSession() {
    guard let current = activeSession,
      let index = sessions.firstIndex(where: { $0.id == current.id }),
      sessions.count > 1
    else { return }
    activeSession = sessions[(index + 1) % sessions.count]
  }

  func prevSession() {
    guard let current = activeSession,
      let index = sessions.firstIndex(where: { $0.id == current.id }),
      sessions.count > 1
    else { return }
    activeSession = sessions[(index - 1 + sessions.count) % sessions.count]
  }

  func moveActiveSessionUp() {
    guard let current = activeSession,
      let index = sessions.firstIndex(where: { $0.id == current.id }),
      index > 0
    else { return }
    sessions.swapAt(index, index - 1)
  }

  func moveActiveSessionDown() {
    guard let current = activeSession,
      let index = sessions.firstIndex(where: { $0.id == current.id }),
      index < sessions.count - 1
    else { return }
    sessions.swapAt(index, index + 1)
  }

  func moveSessions(from source: IndexSet, to destination: Int) {
    sessions.move(fromOffsets: source, toOffset: destination)
  }

  // MARK: - Lookup convenience

  func activePaneInfo() -> (session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    guard let session = activeSession,
      let tab = session.activeTab,
      let pane = tab.activePane
    else { return nil }
    return (session, tab, pane)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter WindowStateTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/WindowState.swift MisttyTests/Models/WindowStateTests.swift
git commit -m "$(cat <<'EOF'
feat: add WindowState (per-window session container)

Owns sessions/activeSession/navigation methods relocated from
SessionStore. ID generators delegate up to WindowsStore so global
uniqueness holds across windows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Lookups + NSWindow registry on `WindowsStore`

**Files:**

- Modify: `Mistty/Models/WindowsStore.swift`
- Modify: `MisttyTests/Models/WindowsStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `MisttyTests/Models/WindowsStoreTests.swift`:

```swift
@MainActor
struct WindowsStoreLookupTests {
  @Test
  func sessionByIdFindsAcrossWindows() {
    let store = WindowsStore()
    let a = store.createWindow()
    let b = store.createWindow()
    let s1 = a.createSession(name: "a", directory: URL(fileURLWithPath: "/"))
    let s2 = b.createSession(name: "b", directory: URL(fileURLWithPath: "/"))

    let foundA = store.session(byId: s1.id)
    let foundB = store.session(byId: s2.id)
    #expect(foundA?.window.id == a.id)
    #expect(foundA?.session.id == s1.id)
    #expect(foundB?.window.id == b.id)
    #expect(foundB?.session.id == s2.id)
    #expect(store.session(byId: 99) == nil)
  }

  @Test
  func windowByIdFindsExisting() {
    let store = WindowsStore()
    let a = store.createWindow()
    #expect(store.window(byId: a.id)?.id == a.id)
    #expect(store.window(byId: 999) == nil)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter WindowsStoreLookupTests
```

Expected: build fails with "value of type 'WindowsStore' has no member 'session(byId:)'".

- [ ] **Step 3: Add lookup helpers + NSWindow registry**

Append to `Mistty/Models/WindowsStore.swift` (inside the class, before the closing brace):

```swift
  // MARK: - Lookup helpers

  func window(byId id: Int) -> WindowState? {
    windows.first { $0.id == id }
  }

  func session(byId id: Int) -> (window: WindowState, session: MisttySession)? {
    for window in windows {
      if let session = window.sessions.first(where: { $0.id == id }) {
        return (window, session)
      }
    }
    return nil
  }

  func tab(byId id: Int) -> (window: WindowState, session: MisttySession, tab: MisttyTab)? {
    for window in windows {
      for session in window.sessions {
        if let tab = session.tabs.first(where: { $0.id == id }) {
          return (window, session, tab)
        }
      }
    }
    return nil
  }

  func pane(byId id: Int) -> (window: WindowState, session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    for window in windows {
      for session in window.sessions {
        for tab in session.tabs {
          if let pane = tab.panes.first(where: { $0.id == id }) {
            return (window, session, tab, pane)
          }
        }
      }
    }
    return nil
  }

  func popup(byId id: Int) -> (window: WindowState, session: MisttySession, popup: PopupState)? {
    for window in windows {
      for session in window.sessions {
        if let popup = session.popups.first(where: { $0.id == id }) {
          return (window, session, popup)
        }
      }
    }
    return nil
  }

  // MARK: - NSWindow registry

  @discardableResult
  func registerNSWindow(_ window: NSWindow, for state: WindowState) -> Int {
    if let existing = trackedNSWindows.firstIndex(where: { $0.window === window }) {
      // Update binding if the same NSWindow re-registers (e.g. WindowAccessor
      // fires a second time after state restoration).
      trackedNSWindows[existing] = TrackedWindow(id: trackedNSWindows[existing].id, window: window, state: state)
      return trackedNSWindows[existing].id
    }
    let id = state.id
    trackedNSWindows.append(TrackedWindow(id: id, window: window, state: state))
    return id
  }

  func unregisterNSWindow(_ window: NSWindow) {
    trackedNSWindows.removeAll { $0.window === window }
  }

  func trackedNSWindow(byId id: Int) -> TrackedWindow? {
    trackedNSWindows.first { $0.id == id }
  }

  // MARK: - Focus helpers

  /// True iff the system's keyWindow is one of our tracked terminal windows.
  /// Used to gate app-wide shortcuts like Cmd-W when an auxiliary window
  /// (Settings, etc.) has focus.
  func isTerminalWindowKey() -> Bool {
    guard let key = NSApp.keyWindow else { return false }
    return trackedNSWindows.contains { $0.window === key }
  }

  /// True iff the system's keyWindow is the NSWindow tracked for `state`.
  /// The window-scoped variant — used by per-window NSEvent monitors and
  /// notification handlers so only the focused window acts.
  func isActiveTerminalWindow(state: WindowState) -> Bool {
    guard let key = NSApp.keyWindow else { return false }
    return trackedNSWindows.contains { $0.window === key && $0.state?.id == state.id }
  }

  /// The `WindowState` whose tracked NSWindow is the keyWindow, if any.
  func focusedWindow() -> WindowState? {
    guard let key = NSApp.keyWindow else { return nil }
    return trackedNSWindows.first { $0.window === key }?.state
  }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter WindowsStoreLookupTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/WindowsStore.swift MisttyTests/Models/WindowsStoreTests.swift
git commit -m "$(cat <<'EOF'
feat: add cross-window lookups, NSWindow registry, focus helpers

session/tab/pane/popup(byId:) iterate all windows and return the
owning WindowState. registerNSWindow links an NSWindow to a
WindowState so isActiveTerminalWindow can distinguish "this window"
from "any tracked terminal window".

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Snapshot v2 schema and migration

The decoder layer changes shape; the encoder follows. v1 payloads in users' saved-state fold transparently into a single window so the upgrade is invisible.

### Task 4: `WindowSnapshot` DTO + `WorkspaceSnapshot` v2

**Files:**

- Create: `MisttyShared/Snapshot/WindowSnapshot.swift`
- Modify: `MisttyShared/Snapshot/WorkspaceSnapshot.swift`
- Modify: `Mistty/Models/WindowsStore.swift` (replace `_PlaceholderWindowSnapshot`)

- [ ] **Step 1: Write failing tests**

Create `MisttyTests/Snapshot/WorkspaceSnapshotMigrationTests.swift`:

```swift
import Testing
import Foundation
@testable import MisttyShared

struct WorkspaceSnapshotMigrationTests {
  @Test
  func decodesV2Directly() throws {
    let json = #"""
    {
      "version": 2,
      "windows": [
        {
          "id": 1,
          "sessions": [],
          "activeSessionID": null
        }
      ],
      "activeWindowID": 1
    }
    """#
    let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
    #expect(snap.version == 2)
    #expect(snap.windows.count == 1)
    #expect(snap.windows[0].id == 1)
    #expect(snap.activeWindowID == 1)
  }

  @Test
  func migratesV1IntoSingleWindow() throws {
    let json = #"""
    {
      "version": 1,
      "sessions": [
        {
          "id": 7,
          "name": "demo",
          "customName": null,
          "directory": "/Users/manu",
          "sshCommand": null,
          "lastActivatedAt": "2026-04-22T10:00:00Z",
          "tabs": [],
          "activeTabID": null
        }
      ],
      "activeSessionID": 7
    }
    """#
    let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
    #expect(snap.version == 2)
    #expect(snap.windows.count == 1)
    let win = snap.windows[0]
    #expect(win.id == 1)
    #expect(win.sessions.count == 1)
    #expect(win.sessions[0].id == 7)
    #expect(win.activeSessionID == 7)
    #expect(snap.activeWindowID == 1)
  }

  @Test
  func unsupportedVersionRecorded() throws {
    let json = #"""{"version": 99, "windows": []}"""#
    let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
    #expect(snap.unsupportedVersion == 99)
  }

  @Test
  func roundTripsV2EncodeDecode() throws {
    let original = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 3,
          sessions: [],
          activeSessionID: nil
        )
      ],
      activeWindowID: 3
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    #expect(decoded.version == 2)
    #expect(decoded.windows.count == 1)
    #expect(decoded.windows[0].id == 3)
    #expect(decoded.activeWindowID == 3)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter WorkspaceSnapshotMigrationTests
```

Expected: build fails with "cannot find 'WindowSnapshot' in scope".

- [ ] **Step 3: Create `WindowSnapshot`**

Create `MisttyShared/Snapshot/WindowSnapshot.swift`:

```swift
import Foundation

public struct WindowSnapshot: Codable, Sendable {
  public let id: Int
  public let sessions: [SessionSnapshot]
  public let activeSessionID: Int?

  public init(id: Int, sessions: [SessionSnapshot], activeSessionID: Int?) {
    self.id = id
    self.sessions = sessions
    self.activeSessionID = activeSessionID
  }
}
```

- [ ] **Step 4: Read the current `WorkspaceSnapshot` to know what to replace**

Read the existing file before editing:

```bash
cat MisttyShared/Snapshot/WorkspaceSnapshot.swift
```

- [ ] **Step 5: Rewrite `WorkspaceSnapshot` for v2 with v1 migration**

Overwrite `MisttyShared/Snapshot/WorkspaceSnapshot.swift`:

```swift
import Foundation

public struct WorkspaceSnapshot: Codable, Sendable {
  public static let currentVersion = 2

  public let version: Int
  public let windows: [WindowSnapshot]
  public let activeWindowID: Int?

  /// Set when decoding a payload whose version is neither 1 (migrated) nor
  /// the current version. Callers bail to empty state with a log line.
  public var unsupportedVersion: Int?

  public init(version: Int, windows: [WindowSnapshot], activeWindowID: Int?) {
    self.version = version
    self.windows = windows
    self.activeWindowID = activeWindowID
    self.unsupportedVersion = nil
  }

  // MARK: - Codable with v1 migration

  enum CodingKeys: String, CodingKey {
    case version
    case windows
    case activeWindowID
    // v1 fields (read-only during migration)
    case sessions
    case activeSessionID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try container.decode(Int.self, forKey: .version)

    if decodedVersion == 2 {
      self.version = 2
      self.windows = try container.decode([WindowSnapshot].self, forKey: .windows)
      self.activeWindowID = try container.decodeIfPresent(Int.self, forKey: .activeWindowID)
      self.unsupportedVersion = nil
    } else if decodedVersion == 1 {
      // Migrate: the v1 payload's flat sessions become a single synthetic
      // window with id=1. nextWindowID will be bumped past 1 by
      // advanceIDCounters during restore.
      let v1Sessions = try container.decode([SessionSnapshot].self, forKey: .sessions)
      let v1ActiveSessionID = try container.decodeIfPresent(Int.self, forKey: .activeSessionID)
      self.version = WorkspaceSnapshot.currentVersion
      self.windows = [
        WindowSnapshot(id: 1, sessions: v1Sessions, activeSessionID: v1ActiveSessionID)
      ]
      self.activeWindowID = 1
      self.unsupportedVersion = nil
    } else {
      // Future / unknown version. Mark unsupported and let the caller bail.
      self.version = decodedVersion
      self.windows = []
      self.activeWindowID = nil
      self.unsupportedVersion = decodedVersion
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(windows, forKey: .windows)
    try container.encodeIfPresent(activeWindowID, forKey: .activeWindowID)
  }
}
```

- [ ] **Step 6: Replace `_PlaceholderWindowSnapshot` in `WindowsStore.swift`**

Open `Mistty/Models/WindowsStore.swift`. Add `import MisttyShared` to the imports:

```swift
import AppKit
import Foundation
import MisttyShared
import SwiftUI
```

Replace:

```swift
  var recentlyClosed: [_PlaceholderWindowSnapshot] = []
```

with:

```swift
  var recentlyClosed: [WindowSnapshot] = []
```

Delete the placeholder typealias at the bottom of the file:

```swift
// Placeholder — the real `WindowSnapshot` arrives in Phase 2 (Task 7).
// Defined here as `_PlaceholderWindowSnapshot` aliased so we can swap later.
typealias _PlaceholderWindowSnapshot = Void
```

- [ ] **Step 7: Run tests to verify they pass**

```bash
swift test --filter WorkspaceSnapshotMigrationTests
swift test --filter WindowsStoreTests
swift test --filter WindowStateTests
```

Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add MisttyShared/Snapshot/WindowSnapshot.swift \
        MisttyShared/Snapshot/WorkspaceSnapshot.swift \
        Mistty/Models/WindowsStore.swift \
        MisttyTests/Snapshot/WorkspaceSnapshotMigrationTests.swift
git commit -m "$(cat <<'EOF'
feat: WorkspaceSnapshot v2 with windows array + v1 migration

v2 wraps sessions in WindowSnapshot. v1 payloads decode transparently
into a single synthetic window so existing users don't lose state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Update existing `WorkspaceSnapshotTests` and `SessionStoreSnapshotTests`

**Files:**

- Modify: `MisttyTests/Snapshot/WorkspaceSnapshotTests.swift`
- Modify: `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift`

These existing tests reference v1 schema fields directly (`sessions`, `activeSessionID` at top level). They need updating to v2 shape, but should not be deleted — they cover the encoder/decoder round-trip and the layout-tree restoration logic, both still relevant.

- [ ] **Step 1: Read both files**

```bash
cat MisttyTests/Snapshot/WorkspaceSnapshotTests.swift
cat MisttyTests/Snapshot/SessionStoreSnapshotTests.swift
```

Note current shape: tests construct `WorkspaceSnapshot(version: 1, sessions: [...], activeSessionID: ...)`.

- [ ] **Step 2: Update each test to the v2 shape**

For every `WorkspaceSnapshot(version: 1, sessions: ..., activeSessionID: ...)` construction, change to:

```swift
WorkspaceSnapshot(
  version: 2,
  windows: [
    WindowSnapshot(id: 1, sessions: [...], activeSessionID: ...)
  ],
  activeWindowID: 1
)
```

For tests that previously asserted on `snap.sessions` / `snap.activeSessionID`, update to `snap.windows[0].sessions` / `snap.windows[0].activeSessionID`.

- [ ] **Step 3: Run the tests**

```bash
swift test --filter WorkspaceSnapshotTests
swift test --filter SessionStoreSnapshotTests
```

Expected: all pass against the new schema.

- [ ] **Step 4: Commit**

```bash
git add MisttyTests/Snapshot/
git commit -m "$(cat <<'EOF'
test: update existing snapshot tests to v2 schema

Existing layout/decoder coverage stays — only the WorkspaceSnapshot
construction shape changed. SessionStoreSnapshotTests will be renamed
when SessionStore is deleted in a later task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `WindowsStore.takeSnapshot()` and `restore(from:config:)`

**Files:**

- Create: `Mistty/Models/WindowsStore+Snapshot.swift`
- Modify: `Mistty/Models/WindowsStore.swift` (`appendRestoredWindow` helper if needed)

- [ ] **Step 1: Read the existing `SessionStore+Snapshot.swift`**

```bash
cat Mistty/Models/SessionStore+Snapshot.swift
```

The file's `restoreLayoutNode` and `resolveCWD` helpers and `restoreTab` are pure functions. Lift them as-is into the new file.

- [ ] **Step 2: Create the new file**

Create `Mistty/Models/WindowsStore+Snapshot.swift`:

```swift
import Foundation
import MisttyShared

extension WindowsStore {
  func takeSnapshot() -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      version: WorkspaceSnapshot.currentVersion,
      windows: windows.map { window in
        WindowSnapshot(
          id: window.id,
          sessions: window.sessions.map { session in
            SessionSnapshot(
              id: session.id,
              name: session.name,
              customName: session.customName,
              directory: session.directory,
              sshCommand: session.sshCommand,
              lastActivatedAt: session.lastActivatedAt,
              tabs: session.tabs.map { tab in
                TabSnapshot(
                  id: tab.id,
                  customTitle: tab.customTitle,
                  directory: tab.directory,
                  layout: snapshotLayout(tab.layout.root),
                  activePaneID: tab.activePane?.id
                )
              },
              activeTabID: session.activeTab?.id
            )
          },
          activeSessionID: window.activeSession?.id
        )
      },
      activeWindowID: activeWindow?.id
    )
  }

  func restore(from snapshot: WorkspaceSnapshot, config: RestoreConfig) {
    if let unsupported = snapshot.unsupportedVersion {
      DebugLog.shared.log(
        "restore",
        "unsupported snapshot version \(unsupported); starting empty")
      return
    }

    // Clear current state. Windows are stored fresh from snapshot.
    let existing = windows
    for state in existing { closeWindow(state) }

    var maxWindowID = 0, maxSessionID = 0, maxTabID = 0, maxPaneID = 0

    for windowSnap in snapshot.windows {
      maxWindowID = max(maxWindowID, windowSnap.id)
      let state = WindowState(id: windowSnap.id, store: self)

      for sessionSnap in windowSnap.sessions {
        maxSessionID = max(maxSessionID, sessionSnap.id)
        let tabIDGen: () -> Int = { [weak self] in self?.generateTabID() ?? 0 }
        let paneIDGen: () -> Int = { [weak self] in self?.generatePaneID() ?? 0 }
        let popupIDGen: () -> Int = { [weak self] in self?.generatePopupID() ?? 0 }

        let session = MisttySession(
          id: sessionSnap.id,
          name: sessionSnap.name,
          directory: sessionSnap.directory,
          exec: nil,
          customName: sessionSnap.customName,
          tabIDGenerator: tabIDGen,
          paneIDGenerator: paneIDGen,
          popupIDGenerator: popupIDGen
        )
        session.sshCommand = sessionSnap.sshCommand
        session.lastActivatedAt = sessionSnap.lastActivatedAt

        for tab in session.tabs { session.closeTab(tab) }

        for tabSnap in sessionSnap.tabs {
          maxTabID = max(maxTabID, tabSnap.id)
          let tab = Self.restoreTab(
            from: tabSnap, paneIDGen: paneIDGen,
            config: config, maxPaneID: &maxPaneID)
          session.addTabByRestore(tab)
        }

        if let activeTabID = sessionSnap.activeTabID,
           let activeTab = session.tabs.first(where: { $0.id == activeTabID }) {
          session.activeTab = activeTab
        } else {
          session.activeTab = session.tabs.first
        }

        state.appendRestoredSession(session)
      }

      if let activeID = windowSnap.activeSessionID,
         let active = state.sessions.first(where: { $0.id == activeID }) {
        state.activeSession = active
      } else {
        state.activeSession = state.sessions.first
      }

      // Push to the FIFO queue; mounting WindowRootViews claim it on appear.
      pendingRestoreStates.append(state)
    }

    advanceIDCounters(
      windowMax: maxWindowID,
      sessionMax: maxSessionID,
      tabMax: maxTabID,
      paneMax: maxPaneID,
      popupMax: 0)

    // activeWindow is wired up post-mount once the NSWindows actually exist.
    pendingActiveWindowID = snapshot.activeWindowID
  }

  // The lift-and-shift helpers from SessionStore+Snapshot.swift:

  fileprivate static func restoreTab(
    from snapshot: TabSnapshot,
    paneIDGen: @escaping () -> Int,
    config: RestoreConfig,
    maxPaneID: inout Int
  ) -> MisttyTab {
    var panes: [Int: MisttyPane] = [:]
    let rootNode = restoreLayoutNode(
      snapshot.layout, config: config, panes: &panes, maxPaneID: &maxPaneID)

    guard let firstPane = panes.values.first else {
      let pane = MisttyPane(id: paneIDGen())
      let tab = MisttyTab(id: snapshot.id, existingPane: pane, paneIDGenerator: paneIDGen)
      return tab
    }
    let tab = MisttyTab(
      id: snapshot.id, existingPane: firstPane, paneIDGenerator: paneIDGen)
    tab.customTitle = snapshot.customTitle
    tab.layout = PaneLayout(root: rootNode)
    tab.refreshPanesFromLayout()

    if let activeID = snapshot.activePaneID,
       let active = tab.panes.first(where: { $0.id == activeID }) {
      tab.activePane = active
    } else {
      tab.activePane = tab.panes.first
    }

    return tab
  }

  fileprivate static func restoreLayoutNode(
    _ snapshot: LayoutNodeSnapshot,
    config: RestoreConfig,
    panes: inout [Int: MisttyPane],
    maxPaneID: inout Int
  ) -> PaneLayoutNode {
    switch snapshot {
    case .leaf(let paneSnap):
      maxPaneID = max(maxPaneID, paneSnap.id)
      let pane = MisttyPane(id: paneSnap.id)
      pane.directory = resolveCWD(paneSnap.directory)
      pane.currentWorkingDirectory = resolveCWD(paneSnap.currentWorkingDirectory)
      if let captured = paneSnap.captured,
         let command = config.resolve(captured) {
        pane.command = command
        pane.useCommandField = false
        pane.execInitialInput = false
      }
      panes[paneSnap.id] = pane
      return .leaf(pane)
    case .split(let dir, let a, let b, let ratio):
      let aNode = restoreLayoutNode(a, config: config, panes: &panes, maxPaneID: &maxPaneID)
      let bNode = restoreLayoutNode(b, config: config, panes: &panes, maxPaneID: &maxPaneID)
      let direction: SplitDirection = (dir == .horizontal) ? .horizontal : .vertical
      return .split(direction, aNode, bNode, CGFloat(ratio))
    }
  }

  fileprivate static func resolveCWD(_ url: URL?) -> URL? {
    guard let url else { return nil }
    let path = url.path
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
      return url
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  fileprivate func snapshotLayout(_ node: PaneLayoutNode) -> LayoutNodeSnapshot {
    switch node {
    case .leaf(let pane):
      let captured = ForegroundProcessResolver.current(for: pane).map {
        CapturedProcess(executable: $0.executable, argv: $0.argv, pid: $0.pid)
      }
      return .leaf(pane: PaneSnapshot(
        id: pane.id,
        directory: pane.directory,
        currentWorkingDirectory: pane.currentWorkingDirectory,
        captured: captured
      ))
    case .empty:
      assertionFailure("PaneLayoutNode.empty in live tree at snapshot time")
      return .leaf(pane: PaneSnapshot(id: 0))
    case .split(let dir, let a, let b, let ratio):
      return .split(
        direction: dir == .horizontal ? .horizontal : .vertical,
        a: snapshotLayout(a),
        b: snapshotLayout(b),
        ratio: Double(ratio)
      )
    }
  }
}
```

- [ ] **Step 3: Add `pendingActiveWindowID` to `WindowsStore`**

Open `Mistty/Models/WindowsStore.swift`. Below the existing `var pendingRestoreStates: [WindowState] = []` line, add:

```swift
  /// Set during `restore(...)` and consumed once windows have mounted —
  /// `WindowRootView.drainPendingRestores()` calls
  /// `windowsStore.applyPendingActiveWindow()` to focus the right NSWindow.
  var pendingActiveWindowID: Int?
```

Add to the same class:

```swift
  func applyPendingActiveWindow() {
    guard let id = pendingActiveWindowID,
          let tracked = trackedNSWindow(byId: id) else { return }
    pendingActiveWindowID = nil
    tracked.window?.makeKeyAndOrderFront(nil)
    activeWindow = tracked.state
  }
```

- [ ] **Step 4: Build to make sure the file compiles**

```bash
swift build 2>&1 | tee /tmp/build.log
```

Expected: builds clean. If `restoreLayoutNode`/`restoreTab` etc. collide with the still-present `SessionStore+Snapshot.swift`, those private/static helpers need different names — Swift allows duplicate names in distinct types/extensions on different host types (`SessionStore` vs `WindowsStore`), so this should compile.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/WindowsStore.swift Mistty/Models/WindowsStore+Snapshot.swift
git commit -m "$(cat <<'EOF'
feat: WindowsStore takeSnapshot/restore (v2 schema)

Lifts the restoreTab / restoreLayoutNode / resolveCWD helpers from
SessionStore+Snapshot.swift into the new file. Restore queues the
hydrated WindowStates onto pendingRestoreStates so mounting
WindowRootViews can claim them FIFO.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — SwiftUI rewiring (single window still working)

Switch `MisttyApp` and `ContentView` over to `WindowsStore`/`WindowState`. **Tasks 7, 8, and 9 must land together** — Task 7's `WindowRootView` references `ContentView(state:, windowsStore:, config:)`, which only exists after Task 8 migrates `ContentView`'s signature, and `MisttyApp` / `AppDelegate` / `IPCService` / `StateRestorationObserver` only know about `WindowsStore` after Task 9. Treat Phase 3 as a single integration step; commit at the end of Task 9 only.

### Task 7: `WindowRootView` shell (no restoration claim yet)

**Files:**

- Create: `Mistty/App/WindowRootView.swift`

- [ ] **Step 1: Create the file with a temporary `EmptyView` placeholder**

The real body wires `ContentView(state:, windowsStore:, config:)` in Task 8 once `ContentView`'s signature changes. Until then, the file compiles with an inert body.

```swift
import AppKit
import MisttyShared
import SwiftUI

struct WindowRootView: View {
  let windowsStore: WindowsStore
  let config: MisttyConfig
  @State private var state: WindowState?
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Group {
      if state != nil {
        // Replaced with `ContentView(state: state, windowsStore: windowsStore, config: config)`
        // in Task 8 step 8 once ContentView's new signature lands.
        EmptyView()
      } else {
        Color.clear
      }
    }
    .onAppear {
      claimOrCreateState()
      // Capture the openWindow action once. Subsequent captures are no-ops
      // (the action is value-typed and stable across mounts).
      if windowsStore.openWindowAction == nil {
        windowsStore.openWindowAction = openWindow
      }
      windowsStore.drainPendingRestores()
      windowsStore.applyPendingActiveWindow()
    }
    .background(
      WindowAccessor { window in
        guard let window, let state else { return }
        _ = windowsStore.registerNSWindow(window, for: state)
      }
    )
  }

  private func claimOrCreateState() {
    if !windowsStore.pendingRestoreStates.isEmpty {
      let claimed = windowsStore.pendingRestoreStates.removeFirst()
      // Restored states aren't yet in `windows`; the registerRestoredWindow
      // call adds them to the registry.
      windowsStore.registerRestoredWindow(claimed)
      state = claimed
      return
    }
    state = windowsStore.createWindow()
  }
}
```

- [ ] **Step 2: Add `drainPendingRestores` and `registerRestoredWindow` to `WindowsStore`**

In `Mistty/Models/WindowsStore.swift` add:

```swift
  /// Append a window state that arrived through `restore(...)`. The
  /// state's `id` was assigned from the snapshot, so we don't generate a
  /// fresh one — but `advanceIDCounters` already bumped past it.
  func registerRestoredWindow(_ state: WindowState) {
    if !windows.contains(where: { $0.id == state.id }) {
      windows.append(state)
    }
  }

  /// After the first WindowRootView mounts and captures `openWindowAction`,
  /// fire it once per remaining state in `pendingRestoreStates`. Each new
  /// SwiftUI window mount will claim the next state at the head of the queue.
  func drainPendingRestores() {
    guard let action = openWindowAction else { return }
    while !pendingRestoreStates.isEmpty {
      action()
    }
  }
```

Note: `OpenWindowAction.callAsFunction()` (no args) opens an additional window of the same `WindowGroup`. The mounting `WindowRootView` in that new window picks up `pendingRestoreStates.removeFirst()`.

- [ ] **Step 3: Build to verify**

```bash
swift build 2>&1 | grep -i error
```

Expected: zero errors. (`ContentView` still takes `store: SessionStore`, so this won't be wired into `MisttyApp` yet.)

- [ ] **Step 4: Commit**

```bash
git add Mistty/App/WindowRootView.swift Mistty/Models/WindowsStore.swift
git commit -m "$(cat <<'EOF'
feat: WindowRootView shell + drainPendingRestores plumbing

Each WindowGroup-spawned window mounts WindowRootView, which claims
a pending restored state or creates a fresh one. drainPendingRestores
fires openWindow() to spawn additional windows during state restoration.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Migrate `ContentView` signature to `state: WindowState, windowsStore: WindowsStore`

**Files:**

- Modify: `Mistty/App/ContentView.swift`
- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/Views/Sidebar/SidebarView.swift`
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift`

This is the largest mechanical change. Do it in one commit.

- [ ] **Step 1: Replace the `ContentView` properties**

Edit `Mistty/App/ContentView.swift`. Find:

```swift
struct ContentView: View {
  var store: SessionStore
  var config: MisttyConfig
```

Replace with:

```swift
struct ContentView: View {
  var state: WindowState
  var windowsStore: WindowsStore
  var config: MisttyConfig
```

- [ ] **Step 2: Replace every `store.activeSession` and `store.sessions` reference**

Mechanical sweep across the file. Use `sed` once:

```bash
sed -i.bak 's/\bstore\.activeSession\b/state.activeSession/g; s/\bstore\.sessions\b/state.sessions/g; s/\bstore\.nextSession\b/state.nextSession/g; s/\bstore\.prevSession\b/state.prevSession/g; s/\bstore\.moveActiveSessionUp\b/state.moveActiveSessionUp/g; s/\bstore\.moveActiveSessionDown\b/state.moveActiveSessionDown/g; s/\bstore\.activePaneInfo\b/state.activePaneInfo/g; s/\bstore\.closeSession\b/state.closeSession/g' Mistty/App/ContentView.swift
rm Mistty/App/ContentView.swift.bak
```

- [ ] **Step 3: Replace `store.isTerminalWindowKey` and `store.trackedWindows`**

```bash
sed -i.bak 's/\bstore\.isTerminalWindowKey\b/windowsStore.isTerminalWindowKey/g; s/\bstore\.trackedWindows\b/windowsStore.trackedNSWindows/g; s/\bstore\.unregisterWindow\b/windowsStore.unregisterNSWindow/g' Mistty/App/ContentView.swift
rm Mistty/App/ContentView.swift.bak
```

- [ ] **Step 4: Replace `store.pane(byId:)` etc.**

```bash
sed -i.bak 's/\bstore\.pane(byId:/windowsStore.pane(byId:/g; s/\bstore\.tab(byId:/windowsStore.tab(byId:/g; s/\bstore\.session(byId:/windowsStore.session(byId:/g; s/\bstore\.popup(byId:/windowsStore.popup(byId:/g' Mistty/App/ContentView.swift
rm Mistty/App/ContentView.swift.bak
```

- [ ] **Step 5: Hand-fix the cross-window pane-by-id iterations**

After Step 2's sed, `handleSetTitle`, `handleRingBell`, `handlePwd`, `handleCloseSurface` now read `for session in state.sessions`. That's wrong — these notifications carry a `paneID` and the pane may live in a _different_ window. Rewrite each to use `windowsStore.pane(byId:)`:

Find blocks like:

```swift
for session in state.sessions {
  for tab in session.tabs {
    if let pane = tab.panes.first(where: { $0.id == paneID }) {
      pane.processTitle = title
      tab.title = title
      return
    }
  }
}
```

Replace with:

```swift
guard let resolved = windowsStore.pane(byId: paneID) else { return }
resolved.pane.processTitle = title
resolved.tab.title = title
```

The bell handler stays slightly different — it needs the _owning_ window's active session/tab to decide whether to mark `hasBell`. Use the destructured tuple:

```swift
private func handleRingBell(_ notification: Notification) {
  guard let paneID = notification.userInfo?["paneID"] as? Int,
    let resolved = windowsStore.pane(byId: paneID)
  else { return }
  let isActiveTabInOwningWindow =
    resolved.window.activeSession?.id == resolved.session.id
    && resolved.session.activeTab?.id == resolved.tab.id
    && windowsStore.activeWindow?.id == resolved.window.id
  if !isActiveTabInOwningWindow {
    resolved.tab.hasBell = true
  }
  updateDockBadge()
  if !NSApp.isActive {
    NSApp.requestUserAttention(.informationalRequest)
  }
}
```

- [ ] **Step 6: Update `updateDockBadge` to sum across all windows**

Find:

```swift
private func updateDockBadge() {
  let count = store.sessions
    .flatMap(\.tabs)
    .filter(\.hasBell)
    .count
  NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
}
```

Replace with:

```swift
private func updateDockBadge() {
  let count = windowsStore.windows
    .flatMap(\.sessions)
    .flatMap(\.tabs)
    .filter(\.hasBell)
    .count
  NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
}
```

- [ ] **Step 7: Remove the now-orphaned `WindowAccessor` registration in `mainContent`**

The window registration moved to `WindowRootView`. In `ContentView.mainContent`'s `.background(WindowAccessor { window in ... })`, change:

```swift
WindowAccessor { window in
  guard let window else { return }
  _ = store.registerWindow(window)
}
```

to:

```swift
// (registration handled in WindowRootView)
EmptyView()
```

Or just delete the `.background(...)` call entirely.

- [ ] **Step 7b: Swap `EmptyView()` for the real `ContentView` in `WindowRootView`**

`ContentView`'s new signature now exists. In `Mistty/App/WindowRootView.swift`, replace:

```swift
      if state != nil {
        // Replaced with `ContentView(state: state, windowsStore: windowsStore, config: config)`
        // in Task 8 step 8 once ContentView's new signature lands.
        EmptyView()
      } else {
        Color.clear
      }
```

with:

```swift
      if let state {
        ContentView(state: state, windowsStore: windowsStore, config: config)
      } else {
        Color.clear
      }
```

- [ ] **Step 8: Update `MisttyApp.swift` to wire `WindowRootView`**

Edit `Mistty/App/MisttyApp.swift`. Find:

```swift
@State private var store = SessionStore()
```

Replace with:

```swift
@State private var windowsStore = WindowsStore()
```

Replace `appDelegate.store = _store.wrappedValue` with:

```swift
appDelegate.windowsStore = _windowsStore.wrappedValue
appDelegate.observer = StateRestorationObserver(windowsStore: _windowsStore.wrappedValue)
```

Replace the `WindowGroup { ContentView(store: store, config: config) ... }` block with:

```swift
WindowGroup {
  WindowRootView(windowsStore: windowsStore, config: config)
    .applyTopSafeArea(style: config.ui.titleBarStyle)
    .onAppear {
      if ipcListener == nil {
        let service = MisttyIPCService(windowsStore: windowsStore)
        let listener = IPCListener(service: service)
        listener.start()
        ipcListener = listener
      }
      applyTitleBarStyleToWindows()
    }
    .onReceive(NotificationCenter.default.publisher(for: .misttyConfigDidReload)) { _ in
      config = MisttyConfig.current
      applyTitleBarStyleToWindows()
      DebugLog.shared.configure(enabled: config.debugLogging)
    }
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
}
```

- [ ] **Step 9: Update `SidebarView` and `SessionManagerViewModel` signatures**

In `SidebarView.swift`, replace the `var store: SessionStore` parameter with:

```swift
var state: WindowState
var windowsStore: WindowsStore
```

Update every `store.activeSession` / `store.sessions` to `state.activeSession` / `state.sessions`. Update every `store.moveSessions` etc. likewise.

In `SessionManagerViewModel.swift`, change `init(store:)` to `init(state: WindowState, windowsStore: WindowsStore)`. Keep the running-sessions list seeded from `state.sessions`. Where it referenced `store.activeSession`, use `state.activeSession`.

- [ ] **Step 10: Update `ContentView.installKeyMonitor`'s `vm` argument and any sites instantiating `SessionManagerViewModel`**

In `ContentView.swift`, find:

```swift
let vm = SessionManagerViewModel(store: store)
```

Replace with:

```swift
let vm = SessionManagerViewModel(state: state, windowsStore: windowsStore)
```

Find the `SidebarView(store: store, ...)` call and replace with `SidebarView(state: state, windowsStore: windowsStore, ...)`.

- [ ] **Step 11: Build**

```bash
swift build 2>&1 | tee /tmp/build.log
```

Expected: builds, but `AppDelegate` and `StateRestorationObserver` and `IPCService` references still expect `store: SessionStore` — those are next tasks. Many errors expected here that the next task fixes; do not commit yet.

If build is clean already (because Swift defers some of those checks to the calling sites), proceed to commit. Otherwise, continue to Task 9 in the same git working tree before committing.

- [ ] **Step 12: Commit (deferred to Task 9 if AppDelegate/IPC errors remain)**

If the build is clean now, commit. If not, see Task 9.

```bash
git add Mistty/App/ContentView.swift Mistty/App/MisttyApp.swift Mistty/App/WindowRootView.swift \
        Mistty/Views/Sidebar/SidebarView.swift Mistty/Views/SessionManager/SessionManagerViewModel.swift
git commit -m "$(cat <<'EOF'
feat: ContentView/MisttyApp use WindowState + WindowsStore

Mechanical migration. SessionStore is still present for AppDelegate /
StateRestorationObserver / IPCService — those are converted next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Migrate `AppDelegate`, `StateRestorationObserver`, `IPCService` to `WindowsStore`

**Files:**

- Modify: `Mistty/App/AppDelegate.swift`
- Modify: `Mistty/Services/StateRestorationObserver.swift`
- Modify: `Mistty/Services/IPCService.swift`

- [ ] **Step 1: `AppDelegate` — swap `store` for `windowsStore`**

Open `Mistty/App/AppDelegate.swift`. Change every `var store: SessionStore?` to `var windowsStore: WindowsStore?`. In the encode/decode hooks, change `store?.takeSnapshot()` to `windowsStore?.takeSnapshot()` and `store?.restore(from: ..., config: ...)` to `windowsStore?.restore(from: ..., config: ...)`.

Add the new override:

```swift
func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
  // Multi-window terminal: closing all windows should keep the app running
  // (Cmd+N spawns a fresh empty window; Reopen Closed Window restores).
  return false
}
```

- [ ] **Step 2: `StateRestorationObserver` — re-root at `windowsStore`**

Open `Mistty/Services/StateRestorationObserver.swift`. Change the property and init:

```swift
let windowsStore: WindowsStore
init(windowsStore: WindowsStore) {
  self.windowsStore = windowsStore
  // ... existing observation setup with the new root
}
```

Inside the observation closure, replace the `store.sessions.forEach { ... }` walk with `windowsStore.windows.forEach { window in window.sessions.forEach { ... } }`.

- [ ] **Step 3: `IPCService` — swap init parameter**

Open `Mistty/Services/IPCService.swift`. Find:

```swift
class MisttyIPCService: NSObject, MisttyServiceProtocol {
  let store: SessionStore
  init(store: SessionStore) { self.store = store; super.init() }
```

Replace with:

```swift
class MisttyIPCService: NSObject, MisttyServiceProtocol {
  let windowsStore: WindowsStore
  init(windowsStore: WindowsStore) {
    self.windowsStore = windowsStore
    super.init()
  }
```

The detailed body changes (per-endpoint global lookups, response `window` field, `createSession` resolution, `createWindow` real impl) come in Phase 5. For now, just keep the file compiling by mechanically renaming `store` → `windowsStore` in scope and patching the obvious mismatches. Use the same sed approach:

```bash
sed -i.bak 's/\bself\.store\b/self.windowsStore/g; s/\bstore\.sessions\b/windowsStore.windows.flatMap { $0.sessions }/g; s/\bstore\.activeSession\b/windowsStore.activeWindow?.activeSession/g; s/\bstore\.pane(byId:/windowsStore.pane(byId:/g; s/\bstore\.tab(byId:/windowsStore.tab(byId:/g; s/\bstore\.session(byId:/windowsStore.session(byId:/g; s/\bstore\.popup(byId:/windowsStore.popup(byId:/g; s/\bstore\.trackedWindow(byId:/windowsStore.trackedNSWindow(byId:/g; s/\bstore\.trackedWindows\b/windowsStore.trackedNSWindows/g' Mistty/Services/IPCService.swift
rm Mistty/Services/IPCService.swift.bak
```

The `pane(byId:)` etc. now return tuples with an extra `window` field at the head — many call sites destructure as `(session, tab, pane)`. Hand-fix those to `(window, session, tab, pane)` where they exist.

For sites that reference `store.activeSession` directly to create a session in IPC's `createSession`, replace with `windowsStore.focusedWindow()` (real resolution comes in Phase 5).

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tee /tmp/build.log
```

Expected: clean build. If destructured tuple sites complain, hand-fix the 5–10 call sites.

- [ ] **Step 5: Run all tests**

```bash
swift test 2>&1 | tee /tmp/test.log
```

Expected: all tests pass. Some old tests instantiate `SessionStore()` — see Phase 4.

- [ ] **Step 6: Commit (Task 8 + 9 together if Task 8 wasn't committed yet)**

```bash
git add Mistty/App/AppDelegate.swift Mistty/Services/StateRestorationObserver.swift \
        Mistty/Services/IPCService.swift
git commit -m "$(cat <<'EOF'
feat: AppDelegate/Observer/IPCService use WindowsStore

Final piece of the SessionStore → WindowsStore + WindowState rewire.
applicationShouldTerminateAfterLastWindowClosed returns false so
closing the last window keeps the app running (Cmd+N respawns).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Active-window guards on notifications and monitors

Single window still works; second window now causes notifications and key events to fire on every `ContentView`. Add the guards.

### Task 10: Active-window guards on `.misttyXxx` notification handlers

**Files:**

- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Identify all window-scoped Mistty notifications**

Run:

```bash
rg "publisher\(for: \.mistty" Mistty/App/ContentView.swift
```

Expected matches (window-scoped — must be guarded):

- `.misttyFocusTabByIndex`
- `.misttyFocusSessionByIndex`
- `.misttyNextTab`
- `.misttyPrevTab`
- `.misttyNextSession`
- `.misttyPrevSession`
- `.misttyMoveSessionUp`
- `.misttyMoveSessionDown`
- `.misttyPopupToggle`
- `.misttyClosePane`
- `.misttyCloseTab`
- `.misttyWindowMode`
- `.misttyCopyMode`
- `.misttyYankHints`
- `.misttyScrollChanged`
- `.misttyNewTab`
- `.misttyNewTabPlain`
- `.misttySplitHorizontal`
- `.misttySplitHorizontalPlain`
- `.misttySplitVertical`
- `.misttySplitVerticalPlain`
- `.misttySessionManager`
- `.misttyToggleTabBar`

**Pane-targeted (not guarded — already filter via `windowsStore.pane(byId:)`):**

- `.ghosttySetTitle`, `.ghosttyRingBell`, `.ghosttyPwd`, `.ghosttyCloseSurface`

- [ ] **Step 2: Add the guard to each window-scoped handler**

For every `.onReceive(NotificationCenter.default.publisher(for: .misttyXxx)) { ... }` in the list above, add as the first line of the closure body:

```swift
guard windowsStore.isActiveTerminalWindow(state: state) else { return }
```

Example transformation:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyNextTab)) { _ in
  guard windowsStore.isActiveTerminalWindow(state: state) else { return }
  state.activeSession?.nextTab()
}
```

- [ ] **Step 3: Build + run**

```bash
swift build
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "$(cat <<'EOF'
feat: scope window-scoped notification handlers to active window

Prevents every ContentView from acting on each NotificationCenter
post once multiple windows are open. Pane-targeted ghostty
notifications stay unguarded — they filter via pane(byId:).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Active-window guards on NSEvent monitors

**Files:**

- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Add guard to each install function**

Each of these functions installs an `NSEvent.addLocalMonitorForEvents`. For each, add `guard windowsStore.isActiveTerminalWindow(state: state) else { return event }` as the first line of the monitor closure (after `[store]` capture lists are removed in favor of `[windowsStore, state]`):

- `installKeyMonitor` (session-manager monitor)
- `installWindowModeMonitor`
- `installCopyModeMonitor`
- `installCtrlNavMonitor`
- `installAltShortcutMonitor`
- `installCloseMonitor`
- `installWindowModeShortcutMonitor`

Example:

```swift
private func installCloseMonitor() {
  closeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [windowsStore, state] event in
    guard windowsStore.isActiveTerminalWindow(state: state) else { return event }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "w"
    else { return event }
    guard windowsStore.isTerminalWindowKey() else { return event }
    let name: Notification.Name =
      flags.contains(.shift) ? .misttyCloseTab : .misttyClosePane
    NotificationCenter.default.post(name: name, object: nil)
    return nil
  }
}
```

The existing `windowsStore.isTerminalWindowKey()` check stays — it's still needed to distinguish "non-terminal window key (Settings)" from "terminal window key" so the auxiliary-window close path works. The new `isActiveTerminalWindow(state:)` check sits _above_ it and filters out "different terminal window is key" cases.

- [ ] **Step 2: Build + sanity check**

```bash
swift build
```

- [ ] **Step 3: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "$(cat <<'EOF'
feat: scope NSEvent monitors to the owning window

Each ContentView's local monitor returns the event unchanged when
its window isn't the key terminal window, so per-window monitors
don't all race for the same keystroke once multiple windows are open.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Delete `SessionStore.swift` and `SessionStore+Snapshot.swift` and update orphaned tests

**Files:**

- Delete: `Mistty/Models/SessionStore.swift`
- Delete: `Mistty/Models/SessionStore+Snapshot.swift`
- Modify or delete: `MisttyTests/Models/SessionStoreTests.swift`
- Modify or delete: `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift`
- Modify: `MisttyTests/MisttyTests.swift`, `MisttyTests/Views/SessionManagerViewModelTests.swift`, `MisttyTests/Models/MisttyTabTests.swift`, `MisttyTests/Models/MisttySessionSidebarLabelTests.swift`, `MisttyTests/Models/PaneLayoutTests.swift`, `MisttyTests/Snapshots/ChromePolishSnapshotTests.swift`, `MisttyTests/Services/IPCServiceTests.swift`, `MisttyTests/Views/SessionManagerViewModelTests.swift` — anywhere that constructs `SessionStore()`

- [ ] **Step 1: Find all remaining `SessionStore` references**

```bash
rg "SessionStore" --type swift
```

- [ ] **Step 2: Replace each test fixture's `SessionStore()` with the helper duo**

Pattern to replace:

```swift
let store = SessionStore()
let session = store.createSession(name: "x", directory: ...)
```

Replace with:

```swift
let store = WindowsStore()
let state = store.createWindow()
let session = state.createSession(name: "x", directory: ...)
```

Anywhere a test referenced `store.activeSession` etc., redirect to `state.activeSession`.

For `IPCServiceTests`, the init is now `MisttyIPCService(windowsStore: store)` (note: `store` is now a `WindowsStore`).

- [ ] **Step 3: Decide for each old test file: keep + relocate, or delete**

- `MisttyTests/Models/SessionStoreTests.swift`: keep but rename to `WindowStateTests` _append_ (you already started this in Task 2 — copy any uncovered behaviors over and delete this file).
- `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift`: rename in place to `WindowsStoreSnapshotTests.swift`. Update internals to construct via `WindowsStore` + `state.createSession`. The decoder behavior tested here (layout-tree restoration, missing-CWD fallback) all still exists, just rooted at `WindowsStore.restore`.

```bash
git mv MisttyTests/Snapshot/SessionStoreSnapshotTests.swift MisttyTests/Snapshot/WindowsStoreSnapshotTests.swift
```

- [ ] **Step 4: Delete the old source files**

```bash
git rm Mistty/Models/SessionStore.swift Mistty/Models/SessionStore+Snapshot.swift MisttyTests/Models/SessionStoreTests.swift
```

- [ ] **Step 5: Build + run tests**

```bash
swift build && swift test 2>&1 | tee /tmp/test.log
grep -E "(failed|passed)" /tmp/test.log | tail -20
```

Expected: clean build, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: delete SessionStore in favor of WindowsStore + WindowState

Final mechanical step of the type split. Tests that constructed
SessionStore now use WindowsStore + a created WindowState. Snapshot
test file renamed; behavior coverage unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — IPC: window-aware reads, mutations, and `createSession`/`createWindow`

The data model is multi-window-ready. Now make the CLI / IPC reflect it.

### Task 13: Add `window: Int` to response models

**Files:**

- Modify: `MisttyShared/Models/SessionResponse.swift`
- Modify: `MisttyShared/Models/TabResponse.swift`
- Modify: `MisttyShared/Models/PaneResponse.swift`
- Modify: `MisttyShared/Models/PopupResponse.swift`

- [ ] **Step 1: Add the field and column to each model**

For `SessionResponse` (template; replicate to Tab/Pane/Popup):

```swift
public struct SessionResponse: Codable, Sendable, PrintableByFormatter {
  public let id: Int
  public let window: Int
  public let name: String
  public let directory: String
  public let tabCount: Int
  public let tabIds: [Int]

  public init(id: Int, window: Int, name: String, directory: String, tabCount: Int, tabIds: [Int]) {
    self.id = id
    self.window = window
    self.name = name
    self.directory = directory
    self.tabCount = tabCount
    self.tabIds = tabIds
  }

  public static func formatHeader() -> [String] {
    ["ID", "Window", "Name", "Directory", "Tabs", "Tab IDs"]
  }

  public func formatRow() -> [String] {
    ["\(self.id)", "\(self.window)", self.name, self.directory,
     "\(self.tabCount)", self.tabIds.map { "\($0)" }.joined(separator: ", ")]
  }
}
```

Apply the analogous transformation to `TabResponse`, `PaneResponse`, `PopupResponse`. The `window` field is the second column in each formatter.

- [ ] **Step 2: Build to discover every IPC response construction site**

```bash
swift build 2>&1 | grep -E "missing argument|expected expression" | head -40
```

The compiler enumerates every site where a `*Response.init` lacks the new `window:` parameter.

- [ ] **Step 3: Fix every `Response` construction in `IPCService.swift`**

For each call site, populate `window:` from the resolved owning `WindowState`. Example:

```swift
// before:
let response = SessionResponse(id: session.id, name: session.name, ...)

// after:
guard let owning = windowsStore.session(byId: session.id) else { ... }
let response = SessionResponse(
  id: session.id,
  window: owning.window.id,
  name: session.name,
  ...
)
```

For list endpoints, iterate `windowsStore.windows` so the owning window is known directly:

```swift
let responses = windowsStore.windows.flatMap { window in
  window.sessions.map { session in
    SessionResponse(
      id: session.id, window: window.id,
      name: session.name, directory: session.directory.path,
      tabCount: session.tabs.count, tabIds: session.tabs.map(\.id))
  }
}
```

- [ ] **Step 4: Build clean**

```bash
swift build
```

Expected: zero errors.

- [ ] **Step 5: Update / add IPC tests**

In `MisttyTests/Services/IPCServiceTests.swift`, ensure existing list tests assert `response.window > 0` for entities created in a `WindowState`.

- [ ] **Step 6: Commit**

```bash
git add MisttyShared/Models/ Mistty/Services/IPCService.swift MisttyTests/Services/IPCServiceTests.swift
git commit -m "$(cat <<'EOF'
feat: add window field to IPC session/tab/pane/popup responses

Every read endpoint now exposes which window owns the entity. List
endpoints iterate windowsStore.windows so the owning window is known
directly without an extra lookup.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: `createSession` window resolution + CLI `--window` flag

**Files:**

- Modify: `MisttyShared/MisttyServiceProtocol.swift`
- Modify: `Mistty/Services/IPCService.swift`
- Modify: `Mistty/Services/IPCListener.swift`
- Modify: `MisttyCLI/Commands/SessionCommand.swift`
- Create: `MisttyTests/Services/IPCServiceWindowResolutionTests.swift`

- [ ] **Step 1: Add `windowID: Int?` to the protocol**

In `MisttyShared/MisttyServiceProtocol.swift`, change:

```swift
func createSession(name: String, directory: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void)
```

to:

```swift
func createSession(name: String, directory: String?, exec: String?, windowID: Int?, reply: @escaping (Data?, Error?) -> Void)
```

- [ ] **Step 2: Write resolution tests (failing)**

Create `MisttyTests/Services/IPCServiceWindowResolutionTests.swift`:

```swift
import Testing
import Foundation
@testable import Mistty
@testable import MisttyShared

@MainActor
struct IPCServiceWindowResolutionTests {
  @Test
  func usesExplicitWindowIDWhenProvided() {
    let store = WindowsStore()
    let a = store.createWindow()
    let b = store.createWindow()
    let resolved = store.resolveTargetWindow(explicit: b.id)
    #expect(resolved?.id == b.id)
    _ = a // suppress unused
  }

  @Test
  func errorsWhenExplicitWindowIDNotFound() {
    let store = WindowsStore()
    _ = store.createWindow()
    let resolved = store.resolveTargetWindow(explicit: 999)
    #expect(resolved == nil)
  }

  @Test
  func fallsBackToFocusedWindowWhenNoExplicit() {
    let store = WindowsStore()
    let a = store.createWindow()
    // focusedWindow() requires NSApp.keyWindow to point at a tracked
    // NSWindow — in unit tests there's no live key window, so
    // resolveTargetWindow returns nil. (Manual UI walkthrough covers
    // the focused-window happy path.)
    let resolved = store.resolveTargetWindow(explicit: nil)
    #expect(resolved == nil)
    _ = a
  }
}
```

- [ ] **Step 3: Add `resolveTargetWindow` to `WindowsStore`**

In `Mistty/Models/WindowsStore.swift`:

```swift
  /// Resolve the target window for a window-scoped create operation.
  /// `explicit` wins; otherwise we fall back to the focused terminal
  /// window. Returns nil if neither resolves.
  func resolveTargetWindow(explicit: Int?) -> WindowState? {
    if let explicit { return window(byId: explicit) }
    return focusedWindow()
  }
```

- [ ] **Step 4: Update `IPCService.createSession` to use the resolver**

In `Mistty/Services/IPCService.swift`:

```swift
func createSession(name: String, directory: String?, exec: String?, windowID: Int?, reply: @escaping (Data?, Error?) -> Void) {
  Task { @MainActor in
    guard let target = self.windowsStore.resolveTargetWindow(explicit: windowID) else {
      reply(nil, MisttyIPC.error(.invalidArgument,
        "no focused window; pass --window <id> or focus a terminal window first"))
      return
    }
    let dir = directory.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    let session = target.createSession(name: name, directory: dir, exec: exec)
    let response = SessionResponse(
      id: session.id, window: target.id,
      name: session.name, directory: session.directory.path,
      tabCount: session.tabs.count, tabIds: session.tabs.map(\.id))
    reply(self.encode(response), nil)
  }
}
```

(Adapt the existing error-code constants to whatever the codebase already uses — search for `MisttyIPC.error` in the file for the local pattern.)

- [ ] **Step 5: Update `IPCListener` payload routing**

In `IPCListener.swift`, find the `createSession` case in the switch and forward the new `windowID` field:

```swift
case "createSession":
  // ... existing decode
  let windowID = payload["windowID"] as? Int
  service.createSession(
    name: name, directory: directory, exec: exec, windowID: windowID,
    reply: reply)
```

- [ ] **Step 6: Add `--window` flag to the CLI**

In `MisttyCLI/Commands/SessionCommand.swift`, find the `Create` subcommand. Add:

```swift
@Option(name: .long, help: "Target window id. Defaults to the focused window.")
var window: Int?
```

In its `run()` method, add `window` to the JSON payload sent through `IPCClient`:

```swift
var payload: [String: Any] = ["name": name]
if let directory { payload["directory"] = directory }
if let exec { payload["exec"] = exec }
if let window { payload["windowID"] = window }
```

- [ ] **Step 7: Run the resolution tests**

```bash
swift test --filter IPCServiceWindowResolutionTests
```

Expected: all 3 pass.

- [ ] **Step 8: Commit**

```bash
git add MisttyShared/MisttyServiceProtocol.swift Mistty/Services/IPCService.swift \
        Mistty/Services/IPCListener.swift Mistty/Models/WindowsStore.swift \
        MisttyCLI/Commands/SessionCommand.swift \
        MisttyTests/Services/IPCServiceWindowResolutionTests.swift
git commit -m "$(cat <<'EOF'
feat: createSession resolves --window or focused-window default

Errors with a clear message when no explicit window is given and no
terminal window is key (CLI invoked from a script while the app
backgrounded). MISTTY_WINDOW env var deliberately not introduced.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: `createWindow` real implementation

**Files:**

- Modify: `Mistty/Services/IPCService.swift`
- Modify: `Mistty/Models/WindowsStore.swift`

- [ ] **Step 1: Add `prepareWindowForIPCCreate` to `WindowsStore`**

In `Mistty/Models/WindowsStore.swift`:

```swift
  /// IPC `createWindow` path. Reserves an id synchronously, builds an empty
  /// `WindowState`, and pushes it onto `pendingRestoreStates` so the next
  /// SwiftUI mount claims it. Returns the reserved id; the caller fires
  /// `openWindowAction` to actually spawn the SwiftUI window.
  func prepareWindowForIPCCreate() -> Int {
    let state = WindowState(id: reserveNextWindowID(), store: self)
    pendingRestoreStates.append(state)
    return state.id
  }
```

- [ ] **Step 2: Update `IPCService.createWindow`**

Replace the current "Not supported" body with:

```swift
func createWindow(reply: @escaping (Data?, Error?) -> Void) {
  Task { @MainActor in
    guard let action = self.windowsStore.openWindowAction else {
      reply(nil, MisttyIPC.error(.invalidArgument,
        "IPC not yet ready; first window must mount before createWindow can spawn additional windows"))
      return
    }
    let id = self.windowsStore.prepareWindowForIPCCreate()
    action()
    let response = WindowResponse(id: id, sessionCount: 0)
    reply(self.encode(response), nil)
  }
}
```

- [ ] **Step 3: Build**

```bash
swift build
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Services/IPCService.swift Mistty/Models/WindowsStore.swift
git commit -m "$(cat <<'EOF'
feat: implement IPC createWindow

Allocates a fresh window id synchronously, queues an empty
WindowState onto pendingRestoreStates, and fires openWindowAction
so the new SwiftUI window mounts and claims it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — Recently-closed + Reopen Closed Window

### Task 16: Snapshot closed windows into `recentlyClosed`

**Files:**

- Modify: `Mistty/Models/WindowsStore.swift`
- Modify: `MisttyTests/Models/WindowsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MisttyTests/Models/WindowsStoreTests.swift`:

```swift
@MainActor
struct WindowsStoreRecentlyClosedTests {
  @Test
  func closeWindowSnapshotsIntoRecentlyClosed() {
    let store = WindowsStore()
    let state = store.createWindow()
    let session = state.createSession(name: "demo", directory: URL(fileURLWithPath: "/tmp"))
    store.closeWindow(state)
    #expect(store.recentlyClosed.count == 1)
    #expect(store.recentlyClosed[0].sessions.count == 1)
    #expect(store.recentlyClosed[0].sessions[0].id == session.id)
  }

  @Test
  func recentlyClosedCappedAtTen() {
    let store = WindowsStore()
    for _ in 0..<15 {
      let state = store.createWindow()
      store.closeWindow(state)
    }
    #expect(store.recentlyClosed.count == 10)
  }

  @Test
  func reopenMostRecentPushesOntoPendingRestoreStates() {
    let store = WindowsStore()
    let state = store.createWindow()
    _ = state.createSession(name: "demo", directory: URL(fileURLWithPath: "/tmp"))
    store.closeWindow(state)
    let restored = store.reopenMostRecentClosed()
    #expect(restored != nil)
    #expect(store.pendingRestoreStates.count == 1)
    #expect(store.recentlyClosed.isEmpty)
  }
}
```

- [ ] **Step 2: Implement**

In `Mistty/Models/WindowsStore.swift`, replace `closeWindow`:

```swift
  func closeWindow(_ state: WindowState) {
    // Snapshot into recently-closed before removal so Reopen Closed Window
    // can rehydrate. In-memory only — wiped on app quit.
    let snapshot = WindowSnapshot(
      id: state.id,
      sessions: state.sessions.map { session in
        // Build SessionSnapshot via the same path takeSnapshot uses.
        // For this in-memory copy we don't need foreground-process capture
        // — closing a window doesn't quit the running shell, but reopening
        // it spawns a fresh shell at the captured CWD anyway.
        SessionSnapshot(
          id: session.id,
          name: session.name,
          customName: session.customName,
          directory: session.directory,
          sshCommand: session.sshCommand,
          lastActivatedAt: session.lastActivatedAt,
          tabs: session.tabs.map { tab in
            TabSnapshot(
              id: tab.id, customTitle: tab.customTitle, directory: tab.directory,
              layout: simpleSnapshotLayout(tab.layout.root),
              activePaneID: tab.activePane?.id)
          },
          activeTabID: session.activeTab?.id)
      },
      activeSessionID: state.activeSession?.id
    )
    recentlyClosed.insert(snapshot, at: 0)
    if recentlyClosed.count > 10 {
      recentlyClosed.removeLast(recentlyClosed.count - 10)
    }
    windows.removeAll { $0.id == state.id }
    if activeWindow?.id == state.id { activeWindow = windows.last }
  }

  /// Stripped-down layout snapshot used by recently-closed (no
  /// foreground-process capture; we just preserve the layout shape and
  /// CWDs). Reopened windows respawn their shells at the captured CWD.
  private func simpleSnapshotLayout(_ node: PaneLayoutNode) -> LayoutNodeSnapshot {
    switch node {
    case .leaf(let pane):
      return .leaf(pane: PaneSnapshot(
        id: pane.id,
        directory: pane.directory,
        currentWorkingDirectory: pane.currentWorkingDirectory,
        captured: nil))
    case .empty:
      return .leaf(pane: PaneSnapshot(id: 0))
    case .split(let dir, let a, let b, let ratio):
      return .split(
        direction: dir == .horizontal ? .horizontal : .vertical,
        a: simpleSnapshotLayout(a),
        b: simpleSnapshotLayout(b),
        ratio: Double(ratio))
    }
  }

  /// Pop the most recently closed window and queue it for restore.
  /// Caller fires `openWindowAction()` to spawn the window.
  func reopenMostRecentClosed() -> Int? {
    guard let snapshot = recentlyClosed.first else { return nil }
    recentlyClosed.removeFirst()

    // Rehydrate the WindowState from the in-memory snapshot using the
    // same restore path as quit-relaunch.
    var maxSessionID = 0, maxTabID = 0, maxPaneID = 0
    let state = WindowState(id: reserveNextWindowID(), store: self)
    let config = MisttyConfig.current.restore
    let tabIDGen: () -> Int = { [weak self] in self?.generateTabID() ?? 0 }
    let paneIDGen: () -> Int = { [weak self] in self?.generatePaneID() ?? 0 }
    let popupIDGen: () -> Int = { [weak self] in self?.generatePopupID() ?? 0 }

    for sessionSnap in snapshot.sessions {
      maxSessionID = max(maxSessionID, sessionSnap.id)
      let session = MisttySession(
        id: generateSessionID(),  // fresh ids on reopen — old ids may collide
        name: sessionSnap.name,
        directory: sessionSnap.directory,
        exec: nil,
        customName: sessionSnap.customName,
        tabIDGenerator: tabIDGen,
        paneIDGenerator: paneIDGen,
        popupIDGenerator: popupIDGen)
      session.sshCommand = sessionSnap.sshCommand
      for tab in session.tabs { session.closeTab(tab) }
      for tabSnap in sessionSnap.tabs {
        maxTabID = max(maxTabID, tabSnap.id)
        let tab = WindowsStore.restoreTab(
          from: tabSnap, paneIDGen: paneIDGen,
          config: config, maxPaneID: &maxPaneID)
        session.addTabByRestore(tab)
      }
      session.activeTab = session.tabs.first
      state.appendRestoredSession(session)
    }
    state.activeSession = state.sessions.first
    pendingRestoreStates.append(state)
    return state.id
  }
```

The `restoreTab` static method is `fileprivate` in `WindowsStore+Snapshot.swift`. Promote to `internal` (drop the `fileprivate`) so this file can call it. Edit `Mistty/Models/WindowsStore+Snapshot.swift`:

```swift
  static func restoreTab(...) -> MisttyTab { ... }
  static func restoreLayoutNode(...) -> PaneLayoutNode { ... }
  static func resolveCWD(...) -> URL? { ... }
```

(Just remove the `fileprivate` modifier on those three.)

- [ ] **Step 3: Run tests**

```bash
swift test --filter WindowsStoreRecentlyClosedTests
```

Expected: 3 pass.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Models/WindowsStore.swift Mistty/Models/WindowsStore+Snapshot.swift \
        MisttyTests/Models/WindowsStoreTests.swift
git commit -m "$(cat <<'EOF'
feat: snapshot closed windows for Cmd+Shift+T reopen

In-memory recently-closed stack capped at 10. Reopen rebuilds the
WindowState and pushes onto pendingRestoreStates so the same
drainPendingRestores plumbing handles the SwiftUI window mount.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 17: "Reopen Closed Window" menu item

**Files:**

- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/App/ContentView.swift` (notification listener)

- [ ] **Step 1: Add the notification name**

In `MisttyApp.swift`, in the `extension Notification.Name`:

```swift
static let misttyReopenClosedWindow = Notification.Name("misttyReopenClosedWindow")
```

- [ ] **Step 2: Add the menu button**

In the `commands` block, after the existing "Close Tab" button:

```swift
Button("Reopen Closed Window") {
  NotificationCenter.default.post(name: .misttyReopenClosedWindow, object: nil)
}
.keyboardShortcut("t", modifiers: [.command, .shift])
```

- [ ] **Step 3: Listen at the app level**

The reopen action isn't window-scoped — it operates on `windowsStore` directly. Add a listener in `MisttyApp.body`'s `WindowGroup { WindowRootView(...).onReceive(...) }` chain (alongside the other app-level listeners):

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyReopenClosedWindow)) { _ in
  guard let _ = windowsStore.reopenMostRecentClosed() else {
    NSSound.beep()
    return
  }
  windowsStore.openWindowAction?()
}
```

- [ ] **Step 4: Build + manual smoke test**

```bash
swift build && just install
```

In the running app: open two windows, close one, hit `Cmd+Shift+T` — the closed window respawns.

- [ ] **Step 5: Commit**

```bash
git add Mistty/App/MisttyApp.swift
git commit -m "$(cat <<'EOF'
feat: Reopen Closed Window menu item (Cmd+Shift+T)

Pulls the most recent WindowSnapshot off recentlyClosed, queues it
for restore, and triggers openWindowAction. Beeps if the stack is
empty.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 7 — Window-disappearance bookkeeping

### Task 18: Wire `WindowRootView.onDisappear` to call `closeWindow`

**Files:**

- Modify: `Mistty/App/WindowRootView.swift`

- [ ] **Step 1: Add the disappear hook**

In `WindowRootView.swift`, add `.onDisappear` to the body chain:

```swift
.onDisappear {
  guard let state else { return }
  // Mirror the existing onDisappear stale-window sweep: only treat this
  // as a window close when the NSWindow really went away (isVisible ==
  // false in the next runloop tick). Spaces/minimize transitions have
  // isVisible == true.
  DispatchQueue.main.async { [windowsStore, state] in
    let stillTracked = windowsStore.trackedNSWindows.first { $0.state?.id == state.id }
    if let stillTracked, stillTracked.window?.isVisible == false {
      windowsStore.unregisterNSWindow(stillTracked.window!)
      windowsStore.closeWindow(state)
    } else if stillTracked == nil {
      // Already swept somewhere else; just remove the WindowState if it
      // still lingers in the windows array.
      windowsStore.closeWindow(state)
    }
  }
}
```

- [ ] **Step 2: Build + manual smoke test**

```bash
swift build && just install
```

Open two windows. Close one. The other still works; `windowsStore.windows.count` (visible via `mistty-cli window list`) is now 1. Quit + relaunch confirms only 1 window restored. Cmd+Shift+T re-spawns the closed one.

- [ ] **Step 3: Commit**

```bash
git add Mistty/App/WindowRootView.swift
git commit -m "$(cat <<'EOF'
feat: WindowRootView.onDisappear retires WindowState on close

Async runloop tick mirrors the prior stale-window sweep so minimize
or spaces transitions don't trigger a close. closeWindow snapshots
into recentlyClosed for Cmd+Shift+T undo.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 8 — Manual UI walkthrough

### Task 19: Run the spec's manual walkthrough

**Files:** none — verification only.

- [x] **Step 1: Install fresh build**

```bash
just install
```

- [ ] **Step 2: Walk through each scenario from the spec**

Each item below maps 1:1 to the spec's "Manual UI walkthrough". Mark off:

- [ ] Cmd+N spawns empty window; original window's panes stay where they are.
- [ ] Two windows side-by-side, multiple sessions/tabs/panes each — keystrokes route to focused window only.
- [ ] Bell ring in background window of background tab → dock badge increments; switching to that tab in that window clears it.
- [ ] Cmd+J in window A shows only A's running sessions; opening a "running" entry from B's list (typed as path) creates an independent session in A.
- [ ] Cmd+W closes pane in focused window only; other window untouched.
- [ ] Quit with multiple windows; relaunch; all windows + states + active markers restore.
- [ ] Close all windows; Cmd+Q; relaunch; one fresh empty window appears.
- [ ] Close one of two windows; Cmd+Shift+T; closed window re-spawns with state intact.
- [ ] `mistty-cli session list` returns sessions from both windows with `window` field populated.
- [ ] `mistty-cli session create --name foo` while window B is focused → session lands in B. With Settings focused (no terminal window key), errors with "no focused window".
- [ ] `mistty-cli window create` returns a fresh window-id; new window appears empty.
- [ ] **v1 → v2 migration**: place a v1 saved-state payload at `~/Library/Saved Application State/com.mistty.app.dev.savedState/` (or whichever bundle ID the dev build uses). Quit + relaunch — single window with all prior sessions appears.

- [ ] **Step 3: File issues for any failure**

Any walkthrough item that fails is a v1 blocker. Triage either by patching (if scope is small) or by recording the gap and returning to the relevant earlier task.

- [ ] **Step 4: Commit any walkthrough fixes** (per-fix commits, not bundled)

---

## Phase 9 — Cleanup

### Task 20: Documentation + PLAN.md

**Files:**

- Modify: `docs/config-example.toml` (no changes expected — multi-window doesn't add config)
- Modify: `PLAN.md`
- Modify: `AGENTS.md` (only if multi-window touches the documented dev workflow)

- [ ] **Step 1: Update PLAN.md "Implemented" section**

Move the "Multiple windows are broken" bullet out of "Misc & Bugs" and add a new entry under `## Implemented`:

```markdown
### Multi-window v1

Spec: `docs/superpowers/specs/2026-04-27-multi-window-v1-design.md`. Plan: `docs/superpowers/plans/2026-04-27-multi-window-v1.md`.

- Each terminal window owns its own sessions/tabs/panes/active markers; opening a new window no longer steals panes from existing windows.
- `WindowsStore` (global registry: ID counters, lookups, NSWindow tracking) + `WindowState` (per-window sessions/active session) replace the prior single `SessionStore`. SwiftUI `WindowGroup` mounts `WindowRootView`; each window claims a `WindowState` from `pendingRestoreStates` (FIFO during restore) or creates a fresh empty one (Cmd+N).
- `WorkspaceSnapshot` v2 with `windows: [WindowSnapshot]`. v1 payloads migrate transparently into a single window so existing users don't lose state.
- Closing the last window keeps the app running (`applicationShouldTerminateAfterLastWindowClosed → false`). Closed windows held in an in-memory `recentlyClosed` stack (capped at 10); `Cmd+Shift+T` reopens.
- IPC: read endpoints (`session list`, `tab list`, `pane list`, `popup list`) flatten across all windows with a new `window` field on each response. Mutating ops by global id (no `--window` needed). `session create` resolves `--window <id>` → focused window → error. `window create` (previously "Not supported") now reserves an id synchronously and spawns the SwiftUI window.
```

The "Multiple windows are broken" line in `Misc & Bugs` is removed. The "Multi-window v2+ followups" subsection added in the spec phase moves under the new `## Implemented` entry as a sub-bullet list, or stays where it is — author's choice.

- [ ] **Step 2: Commit**

```bash
git add PLAN.md
git commit -m "$(cat <<'EOF'
docs: PLAN.md — multi-window v1 implemented

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 21: Merge / PR

- [ ] **Step 1: From the worktree, push the branch**

```bash
git push -u origin feat/multi-window-v1
```

- [ ] **Step 2: Open a PR**

```bash
gh pr create --title "Multi-window v1: independent sessions per window" --body "$(cat <<'EOF'
## Summary

- Splits `SessionStore` into `WindowsStore` (global registry) + `WindowState` (per-window sessions). Each `WindowGroup`-mounted window claims its own state instead of sharing.
- `WorkspaceSnapshot` v2 wraps sessions in a `windows: [WindowSnapshot]` array; v1 payloads migrate transparently.
- IPC reads stay global with a new `window` field on responses; `session create` resolves `--window <id>` or focused window; `window create` is now implemented.
- New "Reopen Closed Window" menu item (Cmd+Shift+T).

Spec: `docs/superpowers/specs/2026-04-27-multi-window-v1-design.md`
Plan: `docs/superpowers/plans/2026-04-27-multi-window-v1.md`

## Test plan

- [ ] All Swift Testing suites pass: `swift test`
- [ ] Manual UI walkthrough (12 items in the plan's Phase 8) passes
- [ ] v1 saved-state migration path verified by upgrading a release build with prior sessions
- [ ] `mistty-cli session list` / `window create` / `session create --window` happy paths

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: After review and merge, clean up the worktree**

```bash
cd /Users/manu/Developer/mistty
git worktree remove .worktrees/multi-window-v1
```

---

## Self-review notes

A pass over this plan against the spec:

- **Spec coverage:** Architecture (Tasks 1–3, 7), ID strategy (Task 1), notification routing (Tasks 10–11), state restoration v2 + migration (Tasks 4–6), IPC (Tasks 13–15), edge cases / dock badge / bell (Task 8), recently-closed (Tasks 16–17), window-disappearance bookkeeping (Task 18), testing (every TDD task + Task 19), risks all addressed across the relevant tasks.
- **Type consistency:** `WindowsStore`, `WindowState`, `WindowSnapshot`, `WorkspaceSnapshot`, `TrackedWindow`, `pendingRestoreStates`, `recentlyClosed`, `openWindowAction` named consistently across tasks.
- **Placeholder scan:** No "TBD" / "TODO" / vague directives. Every code step shows exact code.
- **Tricky bits with explicit handling:** `OpenWindowAction.callAsFunction()` semantic (Task 7); v1 → v2 migration in `WorkspaceSnapshot.init(from:)` (Task 4); cross-window pane bell handling (Task 8 step 5); `restoreTab`'s `fileprivate` → internal promotion (Task 16 step 2); IPC payload field name `windowID` consistency (Tasks 14 step 1, 5, 6).
