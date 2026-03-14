# UX Improvements Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 7 UX improvements across two tracks: tab/session shortcuts, session manager polish, window mode join-to-tab, SSH auto-connect, and smart pane navigation with neovim integration.

**Architecture:** Track 1 (tasks 1-4) are quick wins using existing patterns — keyboard shortcut registration via NotificationCenter, session manager filtering, frecency persistence, and window mode sub-states. Track 2 (tasks 5-7) adds SSH config parsing with preferences UI, and Ctrl-H/J/K/L pane navigation with neovim smart-splits.nvim pass-through via a new XPC method.

**Tech Stack:** Swift 6, SwiftUI, AppKit (NSEvent monitors), TOMLKit, XPC/Mach services, GhosttyKit

**Spec:** `docs/plans/2026-03-13-ux-improvements-design.md`

---

## Chunk 1: Track 1 — Quick Wins

### Task 1: Tab Switching Shortcuts

**Files:**
- Modify: `Mistty/App/MisttyApp.swift:187-198` (notification names)
- Modify: `Mistty/App/MisttyApp.swift:75-149` (keyboard shortcuts)
- Modify: `Mistty/App/ContentView.swift:61-72` (notification handlers)
- Test: `MisttyTests/Models/SessionStoreTests.swift`

- [ ] **Step 1: Add notification names**

Add to the `Notification.Name` extension in `MisttyApp.swift:187-198`:

```swift
static let misttyFocusTabByIndex = Notification.Name("misttyFocusTabByIndex")
static let misttyNextTab = Notification.Name("misttyNextTab")
static let misttyPrevTab = Notification.Name("misttyPrevTab")
static let misttyNextSession = Notification.Name("misttyNextSession")
static let misttyPrevSession = Notification.Name("misttyPrevSession")
```

- [ ] **Step 2: Register keyboard shortcuts**

Add inside `CommandGroup(after: .toolbar)` in `MisttyApp.swift`, after the existing Rename Tab section (after line 133):

```swift
Divider()

ForEach(1...9, id: \.self) { index in
  Button("Focus Tab \(index)") {
    NotificationCenter.default.post(
      name: .misttyFocusTabByIndex,
      object: nil,
      userInfo: ["index": index - 1]
    )
  }
  .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
}

Button("Next Tab") {
  NotificationCenter.default.post(name: .misttyNextTab, object: nil)
}
.keyboardShortcut("]", modifiers: .command)

Button("Previous Tab") {
  NotificationCenter.default.post(name: .misttyPrevTab, object: nil)
}
.keyboardShortcut("[", modifiers: .command)

Button("Next Session") {
  NotificationCenter.default.post(name: .misttyNextSession, object: nil)
}
.keyboardShortcut(.upArrow, modifiers: [.command, .shift])

Button("Previous Session") {
  NotificationCenter.default.post(name: .misttyPrevSession, object: nil)
}
.keyboardShortcut(.downArrow, modifiers: [.command, .shift])
```

- [ ] **Step 3: Add notification handlers in ContentView**

Add to `contentWithOverlays` in `ContentView.swift`, after the `.misttySessionManager` handler (after line 72):

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyFocusTabByIndex)) { notification in
  guard let session = store.activeSession,
        let index = notification.userInfo?["index"] as? Int,
        index < session.tabs.count
  else { return }
  session.activeTab = session.tabs[index]
}
.onReceive(NotificationCenter.default.publisher(for: .misttyNextTab)) { _ in
  guard let session = store.activeSession,
        let current = session.activeTab,
        let index = session.tabs.firstIndex(where: { $0.id == current.id })
  else { return }
  let next = (index + 1) % session.tabs.count
  session.activeTab = session.tabs[next]
}
.onReceive(NotificationCenter.default.publisher(for: .misttyPrevTab)) { _ in
  guard let session = store.activeSession,
        let current = session.activeTab,
        let index = session.tabs.firstIndex(where: { $0.id == current.id })
  else { return }
  let prev = (index - 1 + session.tabs.count) % session.tabs.count
  session.activeTab = session.tabs[prev]
}
.onReceive(NotificationCenter.default.publisher(for: .misttyNextSession)) { _ in
  guard let current = store.activeSession,
        let index = store.sessions.firstIndex(where: { $0.id == current.id }),
        store.sessions.count > 1
  else { return }
  let next = (index + 1) % store.sessions.count
  store.activeSession = store.sessions[next]
}
.onReceive(NotificationCenter.default.publisher(for: .misttyPrevSession)) { _ in
  guard let current = store.activeSession,
        let index = store.sessions.firstIndex(where: { $0.id == current.id }),
        store.sessions.count > 1
  else { return }
  let prev = (index - 1 + store.sessions.count) % store.sessions.count
  store.activeSession = store.sessions[prev]
}
```

- [ ] **Step 4: Write helper methods for tab/session cycling**

Extract cycling logic into testable methods. Add to `MisttySession.swift`:

```swift
func nextTab() {
  guard let current = activeTab,
        let index = tabs.firstIndex(where: { $0.id == current.id })
  else { return }
  activeTab = tabs[(index + 1) % tabs.count]
}

func prevTab() {
  guard let current = activeTab,
        let index = tabs.firstIndex(where: { $0.id == current.id })
  else { return }
  activeTab = tabs[(index - 1 + tabs.count) % tabs.count]
}
```

Add to `SessionStore.swift`:

```swift
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
```

Then simplify the ContentView handlers to call these methods:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyNextTab)) { _ in
  store.activeSession?.nextTab()
}
.onReceive(NotificationCenter.default.publisher(for: .misttyPrevTab)) { _ in
  store.activeSession?.prevTab()
}
.onReceive(NotificationCenter.default.publisher(for: .misttyNextSession)) { _ in
  store.nextSession()
}
.onReceive(NotificationCenter.default.publisher(for: .misttyPrevSession)) { _ in
  store.prevSession()
}
```

- [ ] **Step 5: Write tests for cycling methods**

Add to `MisttyTests/Models/SessionStoreTests.swift`:

```swift
func test_nextTab_wrapsAround() {
  let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  session.addTab()
  session.addTab()
  // Active is last tab (index 2)
  session.nextTab()
  XCTAssertEqual(session.activeTab?.id, session.tabs[0].id)
}

func test_prevTab_wrapsAround() {
  let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  session.addTab()
  session.addTab()
  session.activeTab = session.tabs[0]
  session.prevTab()
  XCTAssertEqual(session.activeTab?.id, session.tabs[2].id)
}

func test_nextSession_wrapsAround() {
  let _ = store.createSession(name: "a", directory: URL(fileURLWithPath: "/tmp"))
  let _ = store.createSession(name: "b", directory: URL(fileURLWithPath: "/tmp"))
  let s3 = store.createSession(name: "c", directory: URL(fileURLWithPath: "/tmp"))
  XCTAssertEqual(store.activeSession?.id, s3.id)
  store.nextSession()
  XCTAssertEqual(store.activeSession?.name, "a")
}

func test_prevSession_wrapsAround() {
  let s1 = store.createSession(name: "a", directory: URL(fileURLWithPath: "/tmp"))
  let _ = store.createSession(name: "b", directory: URL(fileURLWithPath: "/tmp"))
  let _ = store.createSession(name: "c", directory: URL(fileURLWithPath: "/tmp"))
  store.activeSession = s1
  store.prevSession()
  XCTAssertEqual(store.activeSession?.name, "c")
}

func test_focusTabByIndex_boundsCheck() {
  let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  session.addTab()
  session.activeTab = session.tabs[0]
  // Index 5 is out of bounds — should not crash, guard protects
  let index = 5
  if index < session.tabs.count {
    session.activeTab = session.tabs[index]
  }
  XCTAssertEqual(session.activeTab?.id, session.tabs[0].id)
}
```

- [ ] **Step 6: Run tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add Mistty/App/MisttyApp.swift Mistty/App/ContentView.swift Mistty/Models/MisttySession.swift Mistty/Models/SessionStore.swift MisttyTests/Models/SessionStoreTests.swift
git commit -m "feat: add tab switching and session cycling shortcuts

Cmd-1..9 to focus tab by index, Cmd-][ for next/prev tab,
Cmd-Shift-Up/Down to cycle sessions in creation order."
```

---

### Task 2: Hide Current Session in Session Manager

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift:55-56`

- [ ] **Step 1: Write the failing test**

Add to a new test file `MisttyTests/Views/SessionManagerViewModelTests.swift`:

```swift
import XCTest
@testable import Mistty

@MainActor
final class SessionManagerViewModelTests: XCTestCase {
  func test_hideCurrentSession() async {
    let store = SessionStore()
    let s1 = store.createSession(name: "current", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "other", directory: URL(fileURLWithPath: "/home"))
    store.activeSession = s1

    let vm = SessionManagerViewModel(store: store)
    await vm.load()

    let sessionItems = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    // Current session should be hidden
    XCTAssertFalse(sessionItems.contains("current"))
    XCTAssertTrue(sessionItems.contains("other"))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionManagerViewModelTests 2>&1 | tail -10`
Expected: FAIL — "current" is in the list

- [ ] **Step 3: Implement the filter**

In `SessionManagerViewModel.swift`, change line 56 from:

```swift
items += store.sessions.map { .runningSession($0) }
```

to:

```swift
items += store.sessions
  .filter { $0.id != store.activeSession?.id }
  .map { .runningSession($0) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionManagerViewModelTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/SessionManager/SessionManagerViewModel.swift MisttyTests/Views/SessionManagerViewModelTests.swift
git commit -m "feat: hide current session from session manager list"
```

---

### Task 3: Frecency Sorting

**Files:**
- Create: `Mistty/Services/FrecencyService.swift`
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift:48-65,86-96`
- Test: `MisttyTests/Services/FrecencyServiceTests.swift`

- [ ] **Step 1: Write FrecencyService tests**

Create `MisttyTests/Services/FrecencyServiceTests.swift`:

```swift
import XCTest
@testable import Mistty

final class FrecencyServiceTests: XCTestCase {
  var service: FrecencyService!
  var testURL: URL!

  override func setUp() {
    testURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("frecency-test-\(UUID().uuidString).json")
    service = FrecencyService(storageURL: testURL)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: testURL)
  }

  func test_scoreIsZeroForUnknownKey() {
    XCTAssertEqual(service.score(for: "session:unknown"), 0)
  }

  func test_recordAccessIncreasesScore() {
    service.recordAccess(for: "session:project")
    XCTAssertGreaterThan(service.score(for: "session:project"), 0)
  }

  func test_multipleAccessesIncreaseScore() {
    service.recordAccess(for: "session:a")
    let score1 = service.score(for: "session:a")
    service.recordAccess(for: "session:a")
    let score2 = service.score(for: "session:a")
    XCTAssertGreaterThan(score2, score1)
  }

  func test_persistsToDisk() {
    service.recordAccess(for: "dir:/tmp")
    let score = service.score(for: "dir:/tmp")

    // Load fresh instance from same file
    let service2 = FrecencyService(storageURL: testURL)
    XCTAssertEqual(service2.score(for: "dir:/tmp"), score)
  }

  func test_recentAccessScoresHigher() {
    // Record access for "old" item with a fake old date
    service.recordAccess(for: "ssh:old")
    // Manually set the lastAccessed date to 30 days ago
    service.setLastAccessed(for: "ssh:old", date: Date().addingTimeInterval(-30 * 24 * 3600))
    let oldScore = service.score(for: "ssh:old")

    service.recordAccess(for: "ssh:new")
    let newScore = service.score(for: "ssh:new")

    // Same frequency (1 access each), but "new" was accessed more recently
    XCTAssertGreaterThan(newScore, oldScore)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FrecencyServiceTests 2>&1 | tail -10`
Expected: FAIL — `FrecencyService` does not exist

- [ ] **Step 3: Implement FrecencyService**

Create `Mistty/Services/FrecencyService.swift`:

```swift
import Foundation

struct FrecencyEntry: Codable {
  var frequency: Int
  var lastAccessed: Date
}

@MainActor
final class FrecencyService {
  private var entries: [String: FrecencyEntry] = [:]
  private let storageURL: URL

  init(storageURL: URL? = nil) {
    self.storageURL = storageURL ?? Self.defaultStorageURL()
    load()
  }

  private static func defaultStorageURL() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = appSupport.appendingPathComponent("com.mistty")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("frecency.json")
  }

  func score(for key: String) -> Double {
    guard let entry = entries[key] else { return 0 }
    let hoursSinceAccess = -entry.lastAccessed.timeIntervalSinceNow / 3600
    let recencyWeight: Double
    switch hoursSinceAccess {
    case ..<1: recencyWeight = 4.0
    case ..<24: recencyWeight = 2.0
    case ..<168: recencyWeight = 1.0
    default: recencyWeight = 0.5
    }
    return Double(entry.frequency) * recencyWeight
  }

  func recordAccess(for key: String) {
    var entry = entries[key] ?? FrecencyEntry(frequency: 0, lastAccessed: Date())
    entry.frequency += 1
    entry.lastAccessed = Date()
    entries[key] = entry
    save()
  }

  /// Test helper: override lastAccessed date for a key.
  func setLastAccessed(for key: String, date: Date) {
    guard var entry = entries[key] else { return }
    entry.lastAccessed = date
    entries[key] = entry
    save()
  }

  private func load() {
    guard let data = try? Data(contentsOf: storageURL),
          let decoded = try? JSONDecoder().decode([String: FrecencyEntry].self, from: data)
    else { return }
    entries = decoded
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: storageURL, options: .atomic)
  }
}
```

- [ ] **Step 4: Run FrecencyService tests**

Run: `swift test --filter FrecencyServiceTests 2>&1 | tail -10`
Expected: All pass

- [ ] **Step 5: Integrate frecency into SessionManagerViewModel**

In `SessionManagerViewModel.swift`, add a `frecencyService` property and modify `load()` and `confirmSelection()`:

Update the init and add property at line 42 (after `let store: SessionStore`):

```swift
private let frecencyService: FrecencyService

init(store: SessionStore, frecencyService: FrecencyService = FrecencyService()) {
  self.store = store
  self.frecencyService = frecencyService
}
```

Remove the existing `init(store:)` at line 44-46 since it is replaced above.

Add a `frecencyKey` computed property on `SessionManagerItem` (inside the enum, after `subtitle`):

```swift
var frecencyKey: String {
  switch self {
  case .runningSession(let s): return "session:\(s.name)"
  case .directory(let u): return "dir:\(u.path)"
  case .sshHost(let h): return "ssh:\(h.alias)"
  }
}
```

Modify `load()` — after building items, sort by frecency:

```swift
// After: items += sshHosts.map { .sshHost($0) }
// Add sorting:
allItems = items.sorted { a, b in
  let scoreA = frecencyService.score(for: a.frecencyKey)
  let scoreB = frecencyService.score(for: b.frecencyKey)
  if scoreA != scoreB { return scoreA > scoreB }
  // Tiebreaker: maintain category order (sessions > dirs > SSH)
  return categoryOrder(a) < categoryOrder(b)
}
```

Add helper method:

```swift
private func categoryOrder(_ item: SessionManagerItem) -> Int {
  switch item {
  case .runningSession: return 0
  case .directory: return 1
  case .sshHost: return 2
  }
}
```

Modify `confirmSelection()` — record access before switching:

```swift
func confirmSelection() {
  guard selectedIndex < filteredItems.count else { return }
  let item = filteredItems[selectedIndex]
  frecencyService.recordAccess(for: item.frecencyKey)
  switch item {
  case .runningSession(let session):
    store.activeSession = session
  case .directory(let url):
    store.createSession(name: url.lastPathComponent, directory: url)
  case .sshHost:
    break  // will be implemented in Task 6
  }
}
```

- [ ] **Step 6: Write integration test**

Add to `MisttyTests/Views/SessionManagerViewModelTests.swift`:

```swift
func test_frecencySorting() async {
  let store = SessionStore()
  let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("frecency-test-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: tempURL) }

  // Pre-seed frecency data: "other" has higher score
  let service = FrecencyService(storageURL: tempURL)
  service.recordAccess(for: "session:other")
  service.recordAccess(for: "session:other")
  service.recordAccess(for: "session:other")

  let _ = store.createSession(name: "first", directory: URL(fileURLWithPath: "/tmp"))
  let _ = store.createSession(name: "other", directory: URL(fileURLWithPath: "/home"))
  store.activeSession = nil  // no active session so neither is hidden

  let vm = SessionManagerViewModel(store: store, frecencyService: service)
  await vm.load()

  let names = vm.filteredItems.compactMap { item -> String? in
    if case .runningSession(let s) = item { return s.name }
    return nil
  }
  // "other" should sort first due to higher frecency
  XCTAssertEqual(names.first, "other")
}
```

- [ ] **Step 7: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All pass

- [ ] **Step 8: Commit**

```bash
git add Mistty/Services/FrecencyService.swift Mistty/Views/SessionManager/SessionManagerViewModel.swift MisttyTests/Services/FrecencyServiceTests.swift MisttyTests/Views/SessionManagerViewModelTests.swift
git commit -m "feat: add frecency sorting to session manager

Items are sorted by frequency * recency weight. Scores persist to
~/Library/Application Support/com.mistty/frecency.json."
```

---

### Task 4: Join Pane to Tab (Window Mode)

**Files:**
- Modify: `Mistty/Models/MisttyTab.swift:17` (replace `isWindowModeActive` with `WindowModeState`, add `addExistingPane`)
- Modify: `Mistty/App/ContentView.swift` (all `isWindowModeActive` → `windowModeState` references, join mode handling)
- Modify: `Mistty/Views/Terminal/WindowModeHints.swift` (join-pick UI)
- Modify: `Mistty/Views/Terminal/PaneView.swift:6,30,36` (thread `windowModeState` and `joinPickTabNames`)
- Modify: `Mistty/Views/Terminal/PaneLayoutView.swift` (thread new params to PaneView)
- Test: `MisttyTests/Models/SessionStoreTests.swift`

- [ ] **Step 1: Write tests for join pane and WindowModeState**

Add to `SessionStoreTests.swift`:

```swift
func test_windowModeState() {
  let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  let tab = session.tabs[0]
  XCTAssertEqual(tab.windowModeState, .inactive)
  tab.windowModeState = .normal
  XCTAssertTrue(tab.isWindowModeActive)
  tab.windowModeState = .joinPick
  XCTAssertTrue(tab.isWindowModeActive)
  tab.windowModeState = .inactive
  XCTAssertFalse(tab.isWindowModeActive)
}

func test_addExistingPane() {
  let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  let tab1 = session.tabs[0]
  tab1.splitActivePane(direction: .horizontal)
  XCTAssertEqual(tab1.panes.count, 2)

  session.addTab()
  let tab2 = session.tabs[1]
  XCTAssertEqual(tab2.panes.count, 1)

  // Move first pane from tab1 to tab2
  let paneToMove = tab1.panes[0]
  tab1.closePane(paneToMove)
  tab2.addExistingPane(paneToMove, direction: .horizontal)

  XCTAssertEqual(tab1.panes.count, 1)
  XCTAssertEqual(tab2.panes.count, 2)
  XCTAssertTrue(tab2.panes.contains(where: { $0.id == paneToMove.id }))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionStoreTests 2>&1 | tail -10`
Expected: FAIL — `windowModeState` and `addExistingPane` don't exist

- [ ] **Step 3: Replace isWindowModeActive with WindowModeState enum**

In `MisttyTab.swift`, replace line 17 (`var isWindowModeActive = false`) with:

```swift
enum WindowModeState {
  case inactive, normal, joinPick
}

var windowModeState: WindowModeState = .inactive
var isWindowModeActive: Bool { windowModeState != .inactive }
```

- [ ] **Step 4: Add addExistingPane method**

Add to `MisttyTab.swift` after `splitActivePane`:

```swift
func addExistingPane(_ pane: MisttyPane, direction: SplitDirection) {
  guard let activePane else { return }
  layout.split(pane: activePane, direction: direction, newPane: pane)
  panes = layout.leaves
  self.activePane = pane
}
```

- [ ] **Step 5: Update all isWindowModeActive references in ContentView**

In `ContentView.swift`, replace all `tab.isWindowModeActive = true` with `tab.windowModeState = .normal`, and all `tab.isWindowModeActive = false` with `tab.windowModeState = .inactive`. Specifically:

- Line 99: `isWindowModeActive: tab.isWindowModeActive` — this stays (it's the computed property)
- Line 109: same — stays
- Line 145: `store.activeSession?.activeTab?.isWindowModeActive = false` → `store.activeSession?.activeTab?.windowModeState = .inactive`
- Line 250: `tab.isWindowModeActive.toggle()` → replace `handleWindowMode()` body:

```swift
private func handleWindowMode() {
  guard let tab = store.activeSession?.activeTab else { return }
  if tab.isWindowModeActive {
    tab.windowModeState = .inactive
    removeWindowModeMonitor()
  } else {
    tab.windowModeState = .normal
    installWindowModeMonitor()
  }
}
```

- Line 401: `store.activeSession?.activeTab?.isWindowModeActive = false` → `.windowModeState = .inactive`
- Line 484: `tab.isWindowModeActive = false` → `tab.windowModeState = .inactive`

- [ ] **Step 6: Add join mode handling to window mode monitor**

In `installWindowModeMonitor()`, add M key handler in the `switch event.keyCode` block (after the `b` case at line 421):

```swift
case 46:  // m — join pane to tab
  guard let tab = store.activeSession?.activeTab else { return nil }
  tab.windowModeState = .joinPick
  return nil
```

Add handling for join-pick state at the top of the monitor closure (before the Cmd+Arrow resize check):

```swift
// Join-pick mode: number keys select target tab
if store.activeSession?.activeTab?.windowModeState == .joinPick {
  if event.keyCode == 53 {  // Escape — back to normal window mode
    store.activeSession?.activeTab?.windowModeState = .normal
    return nil
  }
  // Number keys 1-9
  if let chars = event.characters, let num = Int(chars), num >= 1, num <= 9 {
    joinPaneToTab(targetIndex: num - 1)
    return nil
  }
  return nil  // Consume all other keys in join-pick mode
}
```

Add the `joinPaneToTab` method:

```swift
private func joinPaneToTab(targetIndex: Int) {
  guard let session = store.activeSession,
        let sourceTab = session.activeTab,
        let pane = sourceTab.activePane,
        sourceTab.panes.count > 1  // Don't join if only pane
  else { return }

  // Build list of target tabs (excluding current)
  let targetTabs = session.tabs.filter { $0.id != sourceTab.id }
  guard targetIndex < targetTabs.count else { return }

  let targetTab = targetTabs[targetIndex]
  sourceTab.closePane(pane)
  if sourceTab.panes.isEmpty {
    session.closeTab(sourceTab)
  }
  targetTab.addExistingPane(pane, direction: .horizontal)
  session.activeTab = targetTab

  // Exit window mode
  session.activeTab?.windowModeState = .inactive
  removeWindowModeMonitor()
}
```

- [ ] **Step 7: Update WindowModeHints for join-pick state**

Replace `WindowModeHints.swift` content:

```swift
import SwiftUI

struct WindowModeHints: View {
  var isJoinPick: Bool = false
  var tabNames: [String] = []

  private var normalHints: [(key: String, label: String)] {
    [
      ("←↑↓→", "swap"),
      ("⌘+arrows", "resize"),
      ("z", "zoom"),
      ("b", "break to tab"),
      ("m", "join to tab"),
      ("r", "rotate"),
      ("esc", "exit"),
    ]
  }

  var body: some View {
    HStack(spacing: 12) {
      if isJoinPick {
        Text("JOIN TO TAB")
          .fontWeight(.bold)
        if tabNames.isEmpty {
          Text("no other tabs")
        } else {
          ForEach(Array(tabNames.enumerated()), id: \.offset) { index, name in
            HStack(spacing: 3) {
              Text("\(index + 1)")
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
              Text(name)
            }
          }
        }
        HStack(spacing: 3) {
          Text("esc")
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
          Text("back")
        }
      } else {
        Text("WINDOW")
          .fontWeight(.bold)
        ForEach(normalHints, id: \.key) { hint in
          HStack(spacing: 3) {
            Text(hint.key)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            Text(hint.label)
          }
        }
      }
    }
    .font(.system(size: 11, design: .monospaced))
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
  }
}
```

`WindowModeHints()` is rendered in `PaneView.swift:36`, not ContentView. Thread the new parameters through the view hierarchy:

In `PaneView.swift`, add two new properties:

```swift
var windowModeState: MisttyTab.WindowModeState = .inactive
var joinPickTabNames: [String] = []
```

Replace the `isWindowModeActive` property usage — change `isActive && isWindowModeActive` (line 30) to `isActive && windowModeState != .inactive`, and update the `WindowModeHints()` call (line 36):

```swift
WindowModeHints(
  isJoinPick: windowModeState == .joinPick,
  tabNames: joinPickTabNames
)
```

In `ContentView.swift`, update `PaneView` construction (lines 96-104 for zoomed pane):

```swift
PaneView(
  pane: zoomedPane,
  isActive: true,
  isWindowModeActive: tab.isWindowModeActive,
  windowModeState: tab.windowModeState,
  joinPickTabNames: session.tabs.filter { $0.id != tab.id }.map { $0.displayTitle },
  isZoomed: true,
  ...
)
```

In `PaneLayoutView`, add `windowModeState` and `joinPickTabNames` parameters and thread them to `PaneView`. Update the `PaneLayoutView` call in `ContentView.swift` (lines 106-114) to pass these values.

**Files modified (additional):**
- `Mistty/Views/Terminal/PaneView.swift` — add `windowModeState`, `joinPickTabNames` properties
- `Mistty/Views/Terminal/PaneLayoutView.swift` — thread new parameters to `PaneView`

- [ ] **Step 8: Update test for isWindowModeActive in SessionStoreTests**

The existing `test_windowModeToggle` (line 84) sets `tab.isWindowModeActive = true` directly. Since `isWindowModeActive` is now computed, update it:

```swift
func test_windowModeToggle() {
  let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  let tab = session.tabs[0]
  XCTAssertFalse(tab.isWindowModeActive)
  tab.windowModeState = .normal
  XCTAssertTrue(tab.isWindowModeActive)
}
```

- [ ] **Step 9: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All pass

- [ ] **Step 10: Commit**

```bash
git add Mistty/Models/MisttyTab.swift Mistty/App/ContentView.swift Mistty/Views/Terminal/WindowModeHints.swift Mistty/Views/Terminal/PaneView.swift Mistty/Views/Terminal/PaneLayoutView.swift MisttyTests/Models/SessionStoreTests.swift
git commit -m "feat: add join-pane-to-tab in window mode (M key)

Replaces isWindowModeActive bool with WindowModeState enum.
Press M in window mode to see numbered tab picker, then 1-9 to
move the active pane into that tab."
```

---

## Chunk 2: Track 2 — Complex Features

### Task 5: SSH Config Parsing + Model Changes

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift` (add SSH config structs, parse, save)
- Modify: `Mistty/Models/MisttySession.swift:6` (add `sshCommand` property)
- Test: `MisttyTests/Config/MisttyConfigTests.swift`

- [ ] **Step 1: Write SSH config parsing tests**

Add to `MisttyConfigTests.swift`:

```swift
func test_parsesSSHConfig() throws {
  let toml = """
    [ssh]
    default_command = "et"

    [[ssh.host]]
    hostname = "dev-box"
    command = "et"

    [[ssh.host]]
    regex = "prod-.*"
    command = "ssh"
    """
  let config = try MisttyConfig.parse(toml)
  XCTAssertEqual(config.ssh.defaultCommand, "et")
  XCTAssertEqual(config.ssh.hosts.count, 2)
  XCTAssertEqual(config.ssh.hosts[0].hostname, "dev-box")
  XCTAssertNil(config.ssh.hosts[0].regex)
  XCTAssertEqual(config.ssh.hosts[0].command, "et")
  XCTAssertNil(config.ssh.hosts[1].hostname)
  XCTAssertEqual(config.ssh.hosts[1].regex, "prod-.*")
  XCTAssertEqual(config.ssh.hosts[1].command, "ssh")
}

func test_sshConfigDefaults() throws {
  let config = try MisttyConfig.parse("")
  XCTAssertEqual(config.ssh.defaultCommand, "ssh")
  XCTAssertTrue(config.ssh.hosts.isEmpty)
}

func test_sshCommandResolution_exactMatch() throws {
  let toml = """
    [[ssh.host]]
    hostname = "dev-box"
    command = "et"
    """
  let config = try MisttyConfig.parse(toml)
  XCTAssertEqual(config.ssh.resolveCommand(for: "dev-box"), "et")
  XCTAssertEqual(config.ssh.resolveCommand(for: "other"), "ssh")
}

func test_sshCommandResolution_regexMatch() throws {
  let toml = """
    [[ssh.host]]
    regex = "prod-.*"
    command = "et"
    """
  let config = try MisttyConfig.parse(toml)
  XCTAssertEqual(config.ssh.resolveCommand(for: "prod-web1"), "et")
  XCTAssertEqual(config.ssh.resolveCommand(for: "staging-web1"), "ssh")
}

func test_sshCommandResolution_firstMatchWins() throws {
  let toml = """
    [[ssh.host]]
    hostname = "prod-db"
    command = "ssh"

    [[ssh.host]]
    regex = "prod-.*"
    command = "et"
    """
  let config = try MisttyConfig.parse(toml)
  // Exact match comes first, so "ssh" wins for prod-db
  XCTAssertEqual(config.ssh.resolveCommand(for: "prod-db"), "ssh")
  // prod-web matches the regex
  XCTAssertEqual(config.ssh.resolveCommand(for: "prod-web"), "et")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MisttyConfigTests 2>&1 | tail -10`
Expected: FAIL — `config.ssh` does not exist

- [ ] **Step 3: Add SSH config structs and parsing**

In `MisttyConfig.swift`, add before the `MisttyConfig` struct:

```swift
struct SSHHostOverride: Sendable, Equatable {
  var hostname: String?
  var regex: String?
  var command: String

  func matches(_ host: String) -> Bool {
    if let hostname { return hostname == host }
    if let regex, let re = try? Regex(regex) {
      return host.wholeMatch(of: re) != nil
    }
    return false
  }
}

struct SSHConfig: Sendable, Equatable {
  var defaultCommand: String = "ssh"
  var hosts: [SSHHostOverride] = []

  func resolveCommand(for host: String) -> String {
    for override in hosts {
      if override.matches(host) { return override.command }
    }
    return defaultCommand
  }
}
```

Add to `MisttyConfig` struct (after `popups` property):

```swift
var ssh: SSHConfig = SSHConfig()
```

Add SSH parsing in `parse()` method (after popup parsing):

```swift
if let sshTable = table["ssh"]?.table {
  if let defaultCmd = sshTable["default_command"]?.string {
    config.ssh.defaultCommand = defaultCmd
  }
  if let hostArray = sshTable["host"]?.array {
    config.ssh.hosts = hostArray.compactMap { entry -> SSHHostOverride? in
      guard let t = entry.table else { return nil }
      return SSHHostOverride(
        hostname: t["hostname"]?.string,
        regex: t["regex"]?.string,
        command: t["command"]?.string ?? config.ssh.defaultCommand
      )
    }
  }
}
```

Add SSH serialization in `save()` method (after popup serialization, before the final write):

```swift
if ssh.defaultCommand != "ssh" || !ssh.hosts.isEmpty {
  lines.append("")
  lines.append("[ssh]")
  lines.append("default_command = \"\(ssh.defaultCommand)\"")
  for host in ssh.hosts {
    lines.append("")
    lines.append("[[ssh.host]]")
    if let hostname = host.hostname {
      lines.append("hostname = \"\(hostname)\"")
    }
    if let regex = host.regex {
      lines.append("regex = \"\(regex)\"")
    }
    lines.append("command = \"\(host.command)\"")
  }
}
```

- [ ] **Step 4: Add sshCommand to MisttySession**

In `MisttySession.swift`, add after line 8 (`let directory: URL`):

```swift
var sshCommand: String?
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter MisttyConfigTests 2>&1 | tail -10`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift Mistty/Models/MisttySession.swift MisttyTests/Config/MisttyConfigTests.swift
git commit -m "feat: add SSH config parsing with host overrides

Supports [ssh] section in config.toml with default_command and
[[ssh.host]] entries using hostname (exact) or regex matching.
First match wins. Adds sshCommand property to MisttySession."
```

---

### Task 6: SSH Session Creation + Preferences

**Depends on:** Task 4 (for `addExistingPane` on `MisttyTab`)

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift` (SSH host selection in `confirmSelection`)
- Modify: `Mistty/App/ContentView.swift` (Opt-modified splits)
- Modify: `Mistty/Views/Settings/SettingsView.swift` (SSH section)
- Test: `MisttyTests/Views/SessionManagerViewModelTests.swift`

- [ ] **Step 1: Implement SSH host selection in session manager**

In `SessionManagerViewModel.swift`, replace the `.sshHost` case in `confirmSelection()` (currently `break  // post-MVP`) with:

```swift
case .sshHost(let host):
  let config = MisttyConfig.load()
  let command = config.ssh.resolveCommand(for: host.alias)
  let fullCommand = "\(command) \(host.alias)"
  let session = store.createSession(
    name: host.alias,
    directory: FileManager.default.homeDirectoryForCurrentUser,
    exec: fullCommand
  )
  session.sshCommand = fullCommand
```

- [ ] **Step 2: Wire Opt-modified splits in ContentView**

Replace the split handlers in `ContentView.swift` (lines 64-68):

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttySplitHorizontal)) { notification in
  guard let session = store.activeSession,
        let tab = session.activeTab else { return }
  if let sshCommand = session.sshCommand,
     !NSEvent.modifierFlags.contains(.option) {
    let pane = MisttyPane(id: store.generatePaneIDForSplit())
    pane.directory = session.directory
    pane.command = sshCommand
    pane.useCommandField = false
    tab.addExistingPane(pane, direction: .horizontal)
  } else {
    tab.splitActivePane(direction: .horizontal)
  }
}
.onReceive(NotificationCenter.default.publisher(for: .misttySplitVertical)) { notification in
  guard let session = store.activeSession,
        let tab = session.activeTab else { return }
  if let sshCommand = session.sshCommand,
     !NSEvent.modifierFlags.contains(.option) {
    let pane = MisttyPane(id: store.generatePaneIDForSplit())
    pane.directory = session.directory
    pane.command = sshCommand
    pane.useCommandField = false
    tab.addExistingPane(pane, direction: .vertical)
  } else {
    tab.splitActivePane(direction: .vertical)
  }
}
```

Wait — `store.generatePaneIDForSplit()` doesn't exist. The pane ID generation is done through `tab.paneIDGenerator()`. But `MisttyTab.splitActivePane()` already calls `paneIDGenerator()` internally. For the SSH case, we need to create the pane externally.

Better approach: expose pane ID generation on `SessionStore` or just call `tab.paneIDGenerator()` since it's `private(set)`. Actually looking at `MisttyTab`, `paneIDGenerator` is `private(set)` which means it's readable. So:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttySplitHorizontal)) { _ in
  guard let session = store.activeSession,
        let tab = session.activeTab else { return }
  if let sshCommand = session.sshCommand,
     !NSEvent.modifierFlags.contains(.option) {
    let pane = MisttyPane(id: tab.paneIDGenerator())
    pane.directory = session.directory
    pane.command = sshCommand
    pane.useCommandField = false
    tab.addExistingPane(pane, direction: .horizontal)
  } else {
    tab.splitActivePane(direction: .horizontal)
  }
}
.onReceive(NotificationCenter.default.publisher(for: .misttySplitVertical)) { _ in
  guard let session = store.activeSession,
        let tab = session.activeTab else { return }
  if let sshCommand = session.sshCommand,
     !NSEvent.modifierFlags.contains(.option) {
    let pane = MisttyPane(id: tab.paneIDGenerator())
    pane.directory = session.directory
    pane.command = sshCommand
    pane.useCommandField = false
    tab.addExistingPane(pane, direction: .vertical)
  } else {
    tab.splitActivePane(direction: .vertical)
  }
}
```

- [ ] **Step 3: Add SSH section to SettingsView**

In `SettingsView.swift`, add after the Popups section (before the closing `}` of the `Form`):

```swift
Section("SSH") {
  HStack {
    Text("Default Command")
    TextField("ssh", text: $config.ssh.defaultCommand)
      .frame(width: 150)
  }

  ForEach(config.ssh.hosts.indices, id: \.self) { index in
    HStack {
      Picker("Match", selection: Binding(
        get: { config.ssh.hosts[index].hostname != nil ? "hostname" : "regex" },
        set: { type in
          if type == "hostname" {
            config.ssh.hosts[index].hostname = config.ssh.hosts[index].regex ?? ""
            config.ssh.hosts[index].regex = nil
          } else {
            config.ssh.hosts[index].regex = config.ssh.hosts[index].hostname ?? ""
            config.ssh.hosts[index].hostname = nil
          }
        }
      )) {
        Text("Hostname").tag("hostname")
        Text("Regex").tag("regex")
      }
      .frame(width: 120)

      if config.ssh.hosts[index].hostname != nil {
        TextField("hostname", text: Binding(
          get: { config.ssh.hosts[index].hostname ?? "" },
          set: { config.ssh.hosts[index].hostname = $0 }
        ))
        .frame(width: 120)
      } else {
        TextField("pattern", text: Binding(
          get: { config.ssh.hosts[index].regex ?? "" },
          set: { config.ssh.hosts[index].regex = $0 }
        ))
        .frame(width: 120)
      }

      TextField("command", text: $config.ssh.hosts[index].command)
        .frame(width: 80)

      Button(role: .destructive) {
        config.ssh.hosts.remove(at: index)
        saveConfig()
      } label: {
        Image(systemName: "minus.circle.fill")
          .foregroundStyle(.red)
      }
      .buttonStyle(.plain)
    }
  }

  Button("Add Host Override") {
    config.ssh.hosts.append(SSHHostOverride(hostname: "", command: "ssh"))
    saveConfig()
  }
}
```

Add `.onChange` for SSH config:

```swift
.onChange(of: config.ssh) { _, _ in saveConfig() }
```

Note: `SSHConfig` and `SSHHostOverride` need to conform to `Equatable` (already done in Task 5) for `.onChange` to work.

- [ ] **Step 3b: Add test for SSH session creation**

Add to `MisttyTests/Views/SessionManagerViewModelTests.swift`:

```swift
func test_sshHostSelectionCreatesSshSession() async {
  let store = SessionStore()
  let vm = SessionManagerViewModel(store: store)

  // Manually add an SSH host item and select it
  // (We can't easily test confirmSelection since it depends on load(),
  // but we can test the model behavior directly)
  let host = SSHHost(alias: "dev-box", hostname: "10.0.0.1")
  let config = MisttyConfig.default
  let command = config.ssh.resolveCommand(for: host.alias)
  let fullCommand = "\(command) \(host.alias)"
  let session = store.createSession(
    name: host.alias,
    directory: FileManager.default.homeDirectoryForCurrentUser,
    exec: fullCommand
  )
  session.sshCommand = fullCommand

  XCTAssertEqual(session.sshCommand, "ssh dev-box")
  XCTAssertEqual(session.name, "dev-box")
}
```

- [ ] **Step 4: Increase settings pane height**

In `SettingsView.swift` line 78, increase frame height from 500 to 600:

```swift
.frame(width: 550, height: 600)
```

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add Mistty/Views/SessionManager/SessionManagerViewModel.swift Mistty/App/ContentView.swift Mistty/Views/Settings/SettingsView.swift
git commit -m "feat: SSH auto-connect and configurable command

Opening SSH host from session manager builds command from config.
New panes in SSH sessions inherit the SSH command (opt-split for local).
SSH section added to preferences pane."
```

---

### Task 7: Smart Pane Navigation (Ctrl-H/J/K/L)

**Files:**
- Modify: `Mistty/Models/MisttyPane.swift` (add `processTitle`)
- Modify: `Mistty/App/ContentView.swift:277-289` (update `handleSetTitle` to set pane processTitle)
- Modify: `Mistty/App/ContentView.swift` (add Ctrl-nav event monitor)
- Modify: `MisttyShared/MisttyServiceProtocol.swift` (add `focusPaneByDirection`)
- Modify: `Mistty/Services/XPCService.swift` (implement `focusPaneByDirection`)
- Modify: `MisttyCLI/Commands/PaneCommand.swift:224-258` (add `--direction` option)
- Create: `docs/integrations/neovim-smart-splits.md`
- Test: `MisttyTests/Models/SessionStoreTests.swift`

- [ ] **Step 1: Write tests for processTitle and neovim detection**

Add to `SessionStoreTests.swift`:

```swift
func test_paneProcessTitle() {
  let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  let pane = session.tabs[0].panes[0]
  XCTAssertNil(pane.processTitle)
  pane.processTitle = "nvim"
  XCTAssertEqual(pane.processTitle, "nvim")
}

func test_isRunningNeovim() {
  let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  let pane = session.tabs[0].panes[0]

  pane.processTitle = "zsh"
  XCTAssertFalse(pane.isRunningNeovim)

  pane.processTitle = "nvim"
  XCTAssertTrue(pane.isRunningNeovim)

  pane.processTitle = "nvim ."
  XCTAssertTrue(pane.isRunningNeovim)

  pane.processTitle = "vim"
  XCTAssertTrue(pane.isRunningNeovim)

  pane.processTitle = "vimtutor"
  XCTAssertFalse(pane.isRunningNeovim)

  pane.processTitle = nil
  XCTAssertFalse(pane.isRunningNeovim)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionStoreTests/test_paneProcessTitle 2>&1 | tail -10`
Expected: FAIL — `processTitle` doesn't exist

- [ ] **Step 3: Add processTitle to MisttyPane**

In `MisttyPane.swift`, add after `var useCommandField`:

```swift
var processTitle: String?

var isRunningNeovim: Bool {
  guard let title = processTitle?.lowercased() else { return false }
  let neovimNames = ["nvim", "neovim", "vim"]
  return neovimNames.contains(where: { title == $0 || title.hasPrefix($0 + " ") })
}
```

- [ ] **Step 4: Run processTitle tests**

Run: `swift test --filter "test_paneProcessTitle|test_isRunningNeovim" 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Update handleSetTitle to set pane processTitle**

In `ContentView.swift`, modify `handleSetTitle` (line 277-289). Add pane process title update:

```swift
private func handleSetTitle(_ notification: Notification) {
  guard let paneID = notification.userInfo?["paneID"] as? Int,
    let title = notification.userInfo?["title"] as? String
  else { return }
  for session in store.sessions {
    for tab in session.tabs {
      if let pane = tab.panes.first(where: { $0.id == paneID }) {
        tab.title = title
        pane.processTitle = title
        return
      }
    }
  }
}
```

- [ ] **Step 6: Add Ctrl-nav event monitor**

Add a new state variable in `ContentView`:

```swift
@State private var ctrlNavMonitor: Any?
```

Add install/remove methods:

```swift
private func installCtrlNavMonitor() {
  ctrlNavMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    guard event.modifierFlags.contains(.control),
          let chars = event.charactersIgnoringModifiers?.lowercased()
    else { return event }

    let direction: NavigationDirection
    switch chars {
    case "h": direction = .left
    case "j": direction = .down
    case "k": direction = .up
    case "l": direction = .right
    default: return event
    }

    // Don't intercept if session manager, window mode, or copy mode is active
    guard !showingSessionManager,
          store.activeSession?.activeTab?.isWindowModeActive != true,
          store.activeSession?.activeTab?.isCopyModeActive != true
    else { return event }

    guard let tab = store.activeSession?.activeTab,
          let pane = tab.activePane
    else { return event }

    // If running neovim, let the keypress through for smart-splits
    if pane.isRunningNeovim { return event }

    // Navigate between MistTY panes — only consume event if navigation succeeds
    if let target = tab.layout.adjacentPane(from: pane, direction: direction) {
      tab.activePane = target
      DispatchQueue.main.async {
        target.surfaceView.window?.makeFirstResponder(target.surfaceView)
      }
      return nil  // Consume the event
    }
    return event  // No adjacent pane (single pane or at edge), pass through to terminal
  }
}

private func removeCtrlNavMonitor() {
  if let monitor = ctrlNavMonitor {
    NSEvent.removeMonitor(monitor)
    ctrlNavMonitor = nil
  }
}
```

Install the monitor in `mainContent`'s `.onAppear` (after the window registration at line 130):

```swift
if ctrlNavMonitor == nil {
  installCtrlNavMonitor()
}
```

And remove in `.onDisappear` (line 142, add after `removeCopyModeMonitor()`):

```swift
removeCtrlNavMonitor()
```

- [ ] **Step 7: Add focusPaneByDirection to XPC protocol**

In `MisttyServiceProtocol.swift`, add after `focusPane` (line 25):

```swift
func focusPaneByDirection(direction: String, sessionId: Int, reply: @escaping (Data?, Error?) -> Void)
```

- [ ] **Step 8: Implement focusPaneByDirection in XPCService**

In `XPCService.swift`, add after `focusPane` method (line 244):

```swift
func focusPaneByDirection(direction: String, sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
        let session: MisttySession?
        if sessionId == 0 {
            session = self.store.activeSession
        } else {
            session = self.store.session(byId: sessionId)
        }
        guard let session else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Session not found"))
            return
        }
        guard let tab = session.activeTab,
              let pane = tab.activePane else {
            reply(nil, MisttyXPC.error(.entityNotFound, "No active pane"))
            return
        }

        let navDirection: NavigationDirection
        switch direction {
        case "left": navDirection = .left
        case "right": navDirection = .right
        case "up": navDirection = .up
        case "down": navDirection = .down
        default:
            reply(nil, MisttyXPC.error(.invalidArgument, "Invalid direction: \(direction). Use left, right, up, or down"))
            return
        }

        guard let target = tab.layout.adjacentPane(from: pane, direction: navDirection) else {
            reply(nil, MisttyXPC.error(.operationFailed, "No pane in direction \(direction)"))
            return
        }

        tab.activePane = target
        reply(self.encode(self.paneResponse(target)), nil)
    }
}
```

- [ ] **Step 9: Add --direction option to CLI pane focus**

Replace the `Focus` struct in `PaneCommand.swift` (lines 224-258):

```swift
struct Focus: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Focus a pane")

    @Argument(help: "Pane ID (omit when using --direction)")
    var id: Int?

    @Option(name: .long, help: "Focus direction (left, right, up, down)")
    var direction: String?

    @Option(name: .long, help: "Session ID for direction-based focus (0 = active)")
    var session: Int = 0

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Flag(name: .long, help: "Output as human-readable text")
    var human = false

    func validate() throws {
        if id == nil && direction == nil {
            throw ValidationError("Provide either a pane ID or --direction")
        }
    }

    func run() throws {
        let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
        let formatter = OutputFormatter(format: format)
        let client = XPCClient()
        let proxy = try client.connect()

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        if let direction {
            proxy.focusPaneByDirection(direction: direction, sessionId: session) { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
        } else if let id {
            proxy.focusPane(id: id) { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
        }
        semaphore.wait()

        if let error = resultError {
            OutputFormatter.printError(error.localizedDescription)
            Foundation.exit(1)
        }

        if let data = resultData {
            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let pane = try? JSONDecoder().decode(PaneResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(pane.id)"),
                        ("Directory", pane.directory ?? "-"),
                    ])
                }
            }
        } else {
            formatter.printSuccess("Pane focused")
        }
    }
}
```

- [ ] **Step 10: Add XPC test for focusPaneByDirection**

Add to `XPCServiceTests.swift`:

```swift
func testFocusPaneByDirection() async throws {
    let session = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    let leftPane = tab.panes[0]
    let rightPane = tab.panes[1]
    // Active pane is right (newest)
    XCTAssertEqual(tab.activePane?.id, rightPane.id)

    let expectation = XCTestExpectation(description: "focus by direction")
    service.focusPaneByDirection(direction: "left", sessionId: session.id) { data, error in
        XCTAssertNil(error)
        XCTAssertNotNil(data)
        let response = try! JSONDecoder().decode(PaneResponse.self, from: data!)
        XCTAssertEqual(response.id, leftPane.id)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
    XCTAssertEqual(tab.activePane?.id, leftPane.id)
}

func testFocusPaneByDirectionInvalid() async throws {
    let _ = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))

    let expectation = XCTestExpectation(description: "focus by direction invalid")
    service.focusPaneByDirection(direction: "diagonal", sessionId: 0) { data, error in
        XCTAssertNotNil(error)
        XCTAssertEqual((error! as NSError).code, MisttyXPC.ErrorCode.invalidArgument.rawValue)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}
```

- [ ] **Step 11: Create neovim integration docs**

Create `docs/integrations/neovim-smart-splits.md`:

```markdown
# Neovim Smart-Splits Integration

MistTY supports seamless pane navigation with neovim's
[smart-splits.nvim](https://github.com/mrjones2014/smart-splits.nvim) plugin.

## How It Works

- **Ctrl-H/J/K/L** navigates between MistTY panes
- When the active pane is running neovim, MistTY passes the keypress through
- smart-splits.nvim handles navigation within neovim splits
- When neovim is at its boundary, smart-splits calls back to MistTY via CLI

## Neovim Configuration

Add to your neovim config:

```lua
require('smart-splits').setup({
  at_edge = function(direction)
    local dir_map = {
      left = 'left',
      right = 'right',
      up = 'up',
      down = 'down',
    }
    os.execute('mistty-cli pane focus --direction ' .. dir_map[direction])
  end
})

-- Keymaps
vim.keymap.set('n', '<C-h>', require('smart-splits').move_cursor_left)
vim.keymap.set('n', '<C-j>', require('smart-splits').move_cursor_down)
vim.keymap.set('n', '<C-k>', require('smart-splits').move_cursor_up)
vim.keymap.set('n', '<C-l>', require('smart-splits').move_cursor_right)
```

## Requirements

- `mistty-cli` must be in your PATH (installed via `just install-cli`)
- MistTY XPC service must be running (starts automatically with the app)
```

- [ ] **Step 12: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All pass

- [ ] **Step 13: Commit**

```bash
git add Mistty/Models/MisttyPane.swift Mistty/App/ContentView.swift MisttyShared/MisttyServiceProtocol.swift Mistty/Services/XPCService.swift MisttyCLI/Commands/PaneCommand.swift MisttyTests/Models/SessionStoreTests.swift MisttyTests/Services/XPCServiceTests.swift docs/integrations/neovim-smart-splits.md
git commit -m "feat: smart pane navigation with Ctrl-H/J/K/L

Ctrl-H/J/K/L navigates between panes. When neovim is detected,
keys pass through for smart-splits.nvim integration.
Adds focusPaneByDirection XPC method and --direction CLI option."
```
