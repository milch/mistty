# CLI Control Remaining TODOs Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Complete the three outstanding CLI control TODOs: ghostty surface integration for sendKeys/runCommand/getText, exec parameter wiring, and stable window IDs.

**Architecture:** sendKeys uses `ghostty_surface_text()` to inject text into a pane's terminal surface. getText uses `ghostty_surface_read_text()` with a full-screen selection. The exec parameter threads through the model layer to `ghostty_surface_config_s.command`. Window IDs use an atomic counter on a new window registry.

**Tech Stack:** Swift 6, libghostty C API, XCTest

---

### Task 1: Implement sendKeys via ghostty_surface_text

**Files:**
- Modify: `Mistty/Services/XPCService.swift` (sendKeys and runCommand methods)
- Test: `MisttyTests/Services/XPCServiceTests.swift`

**Step 1: Write the failing test**

Add to `MisttyTests/Services/XPCServiceTests.swift`:

```swift
func testSendKeysResolvesPane() async throws {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let paneId = session.activeTab!.activePane!.id

    let expectation = XCTestExpectation(description: "send keys")
    service.sendKeys(paneId: paneId, keys: "hello") { data, error in
        // In test environment without ghostty, this should still resolve the pane
        // and attempt the operation (may fail due to no surface, which is OK)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}

func testSendKeysActivePane() async throws {
    let _ = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))

    let expectation = XCTestExpectation(description: "send keys active")
    service.sendKeys(paneId: 0, keys: "hello") { data, error in
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}

func testSendKeysPaneNotFound() async throws {
    let expectation = XCTestExpectation(description: "send keys not found")
    service.sendKeys(paneId: 999, keys: "hello") { data, error in
        XCTAssertNotNil(error)
        XCTAssertEqual((error! as NSError).code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter testSendKeys`
Expected: FAIL — current implementation returns "Not yet implemented" error.

**Step 3: Implement sendKeys**

In `Mistty/Services/XPCService.swift`, replace the sendKeys method:

```swift
nonisolated func sendKeys(paneId: Int, keys: String, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor [store] in
        let targetPane: MisttyPane?
        if paneId == 0 {
            targetPane = store.activePaneInfo()?.pane
        } else {
            targetPane = store.pane(byId: paneId)?.pane
        }
        guard let pane = targetPane else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(paneId) not found"))
            return
        }
        let view = pane.surfaceView
        guard let surface = view.surface else {
            reply(nil, MisttyXPC.error(.operationFailed, "Pane has no active surface"))
            return
        }
        keys.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(keys.utf8.count))
        }
        reply(self.encode([String: String]()), nil)
    }
}
```

**Step 4: Implement runCommand**

Replace the runCommand method to delegate to sendKeys with appended newline:

```swift
nonisolated func runCommand(paneId: Int, command: String, reply: @escaping (Data?, Error?) -> Void) {
    sendKeys(paneId: paneId, keys: command + "\n", reply: reply)
}
```

**Step 5: Run tests**

Run: `swift test`
Expected: sendKeys tests pass (pane resolution works; surface will be nil in tests so the "no active surface" error is returned, which is acceptable — the pane lookup logic is verified).

Note: Update the test expectations to account for this. In test environment without ghostty, the surface is nil, so expect an `operationFailed` error for valid panes. The key test is that paneId=999 returns `entityNotFound` while valid panes return `operationFailed` (surface missing), and paneId=0 resolves to the active pane.

```swift
func testSendKeysResolvesPane() async throws {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let paneId = session.activeTab!.activePane!.id

    let expectation = XCTestExpectation(description: "send keys")
    service.sendKeys(paneId: paneId, keys: "hello") { data, error in
        // Pane found but surface is nil in test → operationFailed (not entityNotFound)
        if let error = error as? NSError {
            XCTAssertEqual(error.code, MisttyXPC.ErrorCode.operationFailed.rawValue)
        }
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}

func testSendKeysActivePane() async throws {
    let _ = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))

    let expectation = XCTestExpectation(description: "send keys active")
    service.sendKeys(paneId: 0, keys: "hello") { data, error in
        if let error = error as? NSError {
            XCTAssertEqual(error.code, MisttyXPC.ErrorCode.operationFailed.rawValue)
        }
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}
```

**Step 6: Commit**

```bash
git add Mistty/Services/XPCService.swift MisttyTests/Services/XPCServiceTests.swift
git commit -m "feat: implement sendKeys and runCommand via ghostty_surface_text"
```

---

### Task 2: Implement getText via ghostty_surface_read_text

**Files:**
- Modify: `Mistty/Services/XPCService.swift` (getText method)
- Test: `MisttyTests/Services/XPCServiceTests.swift`

**Step 1: Write the failing test**

Add to tests:

```swift
func testGetTextResolvesPane() async throws {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let paneId = session.activeTab!.activePane!.id

    let expectation = XCTestExpectation(description: "get text")
    service.getText(paneId: paneId) { data, error in
        // Pane found but surface nil in test
        if let error = error as? NSError {
            XCTAssertEqual(error.code, MisttyXPC.ErrorCode.operationFailed.rawValue)
        }
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}

func testGetTextPaneNotFound() async throws {
    let expectation = XCTestExpectation(description: "get text not found")
    service.getText(paneId: 999) { data, error in
        XCTAssertNotNil(error)
        XCTAssertEqual((error! as NSError).code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter testGetText`
Expected: FAIL.

**Step 3: Implement getText**

The approach: create a selection covering the entire visible screen, then use `ghostty_surface_read_text` to extract the text. The existing copy mode implementation in `ContentView.swift` (lines 476-492) shows the pattern.

Replace getText in `Mistty/Services/XPCService.swift`:

```swift
nonisolated func getText(paneId: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor [store] in
        let targetPane: MisttyPane?
        if paneId == 0 {
            targetPane = store.activePaneInfo()?.pane
        } else {
            targetPane = store.pane(byId: paneId)?.pane
        }
        guard let pane = targetPane else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(paneId) not found"))
            return
        }
        let view = pane.surfaceView
        guard let surface = view.surface else {
            reply(nil, MisttyXPC.error(.operationFailed, "Pane has no active surface"))
            return
        }

        // Get terminal dimensions
        let size = ghostty_surface_size(surface)
        let rows = Int(size.rows)
        let cols = Int(size.columns)

        guard rows > 0, cols > 0 else {
            reply(self.encode(["text": ""]), nil)
            return
        }

        // Read text line by line using single-row selections
        var lines: [String] = []
        for row in 0..<rows {
            var sel = ghostty_selection_s()
            sel.start_row = Int32(row)
            sel.start_col = 0
            sel.end_row = Int32(row)
            sel.end_col = Int32(cols - 1)

            var text = ghostty_text_s()
            if ghostty_surface_read_text(surface, sel, &text) {
                if let ptr = text.text {
                    lines.append(String(cString: ptr))
                }
                ghostty_surface_free_text(surface, &text)
            } else {
                lines.append("")
            }
        }

        let fullText = lines.joined(separator: "\n")
        reply(self.encode(["text": fullText]), nil)
    }
}
```

Note: The exact `ghostty_selection_s` struct fields may differ from what's shown here. Check the actual struct definition in `ghostty.h`. The copy mode implementation in `ContentView.swift` lines 476-485 shows the actual field names used. Adapt accordingly — the fields might be named differently (e.g., `start_x`/`start_y` instead of `start_row`/`start_col`). Use the same pattern as the existing `yankSelection()` method in ContentView.

**Step 4: Run tests**

Run: `swift test`
Expected: All tests pass. getText with valid pane returns `operationFailed` (no surface in tests).

**Step 5: Commit**

```bash
git add Mistty/Services/XPCService.swift MisttyTests/Services/XPCServiceTests.swift
git commit -m "feat: implement getText via ghostty_surface_read_text"
```

---

### Task 3: Wire exec parameter through to ghostty surface config

**Files:**
- Modify: `Mistty/Models/MisttyPane.swift`
- Modify: `Mistty/Views/Terminal/TerminalSurfaceView.swift`
- Modify: `Mistty/Models/MisttyTab.swift`
- Modify: `Mistty/Models/MisttySession.swift`
- Modify: `Mistty/Models/SessionStore.swift`
- Modify: `Mistty/Services/XPCService.swift`
- Test: `MisttyTests/Models/SessionStoreTests.swift`

The `ghostty_surface_config_s` struct has a `command` field (type `const char*`). When set, the surface launches that command instead of the default shell.

**Step 1: Add exec property to MisttyPane**

In `Mistty/Models/MisttyPane.swift`, add an optional command property:

```swift
@Observable
@MainActor
final class MisttyPane: Identifiable {
    let id: Int
    var directory: URL?
    var command: String?

    init(id: Int) {
        self.id = id
    }

    @ObservationIgnored
    lazy var surfaceView: TerminalSurfaceView = {
        let view = TerminalSurfaceView(frame: .zero, workingDirectory: directory, command: command)
        view.pane = self
        return view
    }()
}
```

**Step 2: Update TerminalSurfaceView to accept command**

In `Mistty/Views/Terminal/TerminalSurfaceView.swift`, modify the init to accept and use a command parameter:

```swift
init(frame: NSRect, workingDirectory: URL? = nil, command: String? = nil) {
    self.commandString = command  // Store for C pointer lifetime
    super.init(frame: frame)
    wantsLayer = true

    // ... existing config setup ...

    // Set working directory (existing code)
    if let dir = workingDirectory {
        workingDirectoryPath = dir.path
    }

    // Set command if provided
    if let cmd = commandString {
        cmd.withCString { cmdPtr in
            cfg.command = cmdPtr
            if let path = workingDirectoryPath {
                path.withCString { dirPtr in
                    cfg.working_directory = dirPtr
                    surface = ghostty_surface_new(app, &cfg)
                }
            } else {
                surface = ghostty_surface_new(app, &cfg)
            }
        }
    } else if let path = workingDirectoryPath {
        path.withCString { ptr in
            cfg.working_directory = ptr
            surface = ghostty_surface_new(app, &cfg)
        }
    } else {
        surface = ghostty_surface_new(app, &cfg)
    }
}
```

Add the stored property:
```swift
private var commandString: String?
```

Note: The C pointer from `withCString` is only valid within the closure. The `ghostty_surface_new` call must happen inside the `withCString` closure. Since we might have both command and workingDirectory, we need nested closures.

**Step 3: Thread exec through MisttyTab**

In `Mistty/Models/MisttyTab.swift`, update init to accept optional exec:

```swift
init(id: Int, directory: URL? = nil, exec: String? = nil, paneIDGenerator: @escaping () -> Int) {
    self.id = id
    self.directory = directory
    self.paneIDGenerator = paneIDGenerator
    let pane = MisttyPane(id: paneIDGenerator())
    pane.directory = directory
    pane.command = exec
    layout = PaneLayout(pane: pane)
    panes = [pane]
    activePane = pane
}
```

**Step 4: Thread exec through MisttySession**

In `Mistty/Models/MisttySession.swift`, add a method for creating tabs with exec:

```swift
func addTab(exec: String? = nil) {
    let tab = MisttyTab(id: tabIDGenerator(), directory: directory, exec: exec, paneIDGenerator: paneIDGenerator)
    tabs.append(tab)
    activeTab = tab
}
```

**Step 5: Thread exec through SessionStore**

In `Mistty/Models/SessionStore.swift`, update createSession to accept exec:

```swift
@discardableResult
func createSession(name: String, directory: URL, exec: String? = nil) -> MisttySession {
    let session = MisttySession(id: generateSessionID(), name: name, directory: directory,
                                 tabIDGenerator: { [weak self] in ... },
                                 paneIDGenerator: { [weak self] in ... })
    session.addTab(exec: exec)  // Pass exec to initial tab
    sessions.append(session)
    activeSession = session
    return session
}
```

Wait — check how `MisttySession.init` currently works. It may call `addTab()` in init. If so, the init needs to change:

Currently `MisttySession.init` calls `addTab()` internally. Modify to accept exec and pass it through:

```swift
init(id: Int, name: String, directory: URL, exec: String? = nil,
     tabIDGenerator: @escaping () -> Int, paneIDGenerator: @escaping () -> Int) {
    self.id = id
    self.name = name
    self.directory = directory
    self.tabIDGenerator = tabIDGenerator
    self.paneIDGenerator = paneIDGenerator
    addTab(exec: exec)
}
```

**Step 6: Wire exec in XPCService**

In `Mistty/Services/XPCService.swift`, update createSession:

```swift
let session = store.createSession(name: name, directory: dir, exec: exec)
```

Update createTab:

```swift
session.addTab(exec: exec)
```

Remove the TODO comments.

**Step 7: Write tests**

Add to `MisttyTests/Models/SessionStoreTests.swift`:

```swift
func testCreateSessionWithExec() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"), exec: "nvim")
    XCTAssertEqual(session.tabs.first?.panes.first?.command, "nvim")
}

func testCreateSessionWithoutExec() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    XCTAssertNil(session.tabs.first?.panes.first?.command)
}

func testAddTabWithExec() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    session.addTab(exec: "top")
    XCTAssertEqual(session.tabs.last?.panes.first?.command, "top")
}
```

**Step 8: Run tests**

Run: `swift test`
Expected: All tests pass.

**Step 9: Commit**

```bash
git add Mistty/Models/ Mistty/Views/Terminal/TerminalSurfaceView.swift Mistty/Services/XPCService.swift MisttyTests/
git commit -m "feat: wire exec parameter through to ghostty surface config"
```

---

### Task 4: Stable window IDs via window registry

**Files:**
- Modify: `Mistty/Models/SessionStore.swift` (add window registry)
- Modify: `Mistty/App/ContentView.swift` (register/unregister windows)
- Modify: `Mistty/Services/XPCService.swift` (use registry instead of positional IDs)
- Modify: `MisttyShared/Models/WindowResponse.swift` (add title field)
- Test: `MisttyTests/Models/SessionStoreTests.swift`

**Step 1: Add window registry to SessionStore**

In `Mistty/Models/SessionStore.swift`, add a tracked window type and registry:

```swift
struct TrackedWindow {
    let id: Int
    let window: NSWindow
}

private var nextWindowId = 1
private(set) var trackedWindows: [TrackedWindow] = []

private func generateWindowID() -> Int {
    let id = nextWindowId
    nextWindowId += 1
    return id
}

func registerWindow(_ window: NSWindow) -> Int {
    let id = generateWindowID()
    trackedWindows.append(TrackedWindow(id: id, window: window))
    return id
}

func unregisterWindow(_ window: NSWindow) {
    trackedWindows.removeAll { $0.window === window }
}

func trackedWindow(byId id: Int) -> TrackedWindow? {
    trackedWindows.first { $0.id == id }
}
```

**Step 2: Write tests**

Add to `MisttyTests/Models/SessionStoreTests.swift`:

```swift
func testRegisterWindow() {
    let window = NSWindow()
    let id = store.registerWindow(window)
    XCTAssertEqual(id, 1)
    XCTAssertEqual(store.trackedWindows.count, 1)
}

func testUnregisterWindow() {
    let window = NSWindow()
    let _ = store.registerWindow(window)
    store.unregisterWindow(window)
    XCTAssertTrue(store.trackedWindows.isEmpty)
}

func testWindowIdsAreStable() {
    let w1 = NSWindow()
    let w2 = NSWindow()
    let id1 = store.registerWindow(w1)
    let id2 = store.registerWindow(w2)
    store.unregisterWindow(w1)
    // w2 keeps its original ID
    XCTAssertEqual(store.trackedWindows.first?.id, id2)
    XCTAssertEqual(id1, 1)
    XCTAssertEqual(id2, 2)
}
```

**Step 3: Run tests to verify they fail**

Run: `swift test --filter testRegisterWindow`
Expected: FAIL — methods don't exist yet.

**Step 4: Implement the registry (Step 1 code)**

Add the code from Step 1 to SessionStore.

**Step 5: Run tests**

Run: `swift test`
Expected: PASS.

**Step 6: Register windows in ContentView**

In `Mistty/App/ContentView.swift`, use `.onAppear` and `.onDisappear` to register/unregister the window:

```swift
.onAppear {
    if let window = NSApplication.shared.keyWindow {
        store.registerWindow(window)
    }
}
.onDisappear {
    if let window = NSApplication.shared.keyWindow {
        store.unregisterWindow(window)
    }
}
```

Or better, use an NSWindow lifecycle observer. Check what's simpler given the existing code.

**Step 7: Update XPC window operations**

In `Mistty/Services/XPCService.swift`, replace the positional-index window operations:

```swift
nonisolated func listWindows(reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor [store] in
        let responses = store.trackedWindows.map { tracked in
            WindowResponse(id: tracked.id, sessionCount: store.sessions.count)
        }
        reply(self.encode(responses), nil)
    }
}

nonisolated func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor [store] in
        guard let tracked = store.trackedWindow(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Window \(id) not found"))
            return
        }
        reply(self.encode(WindowResponse(id: tracked.id, sessionCount: store.sessions.count)), nil)
    }
}

nonisolated func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor [store] in
        guard let tracked = store.trackedWindow(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Window \(id) not found"))
            return
        }
        tracked.window.close()
        store.unregisterWindow(tracked.window)
        reply(self.encode([String: String]()), nil)
    }
}

nonisolated func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor [store] in
        guard let tracked = store.trackedWindow(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Window \(id) not found"))
            return
        }
        tracked.window.makeKeyAndOrderFront(nil)
        reply(self.encode([String: String]()), nil)
    }
}
```

**Step 8: Run tests**

Run: `swift test`
Expected: All tests pass.

**Step 9: Commit**

```bash
git add Mistty/Models/SessionStore.swift Mistty/App/ContentView.swift Mistty/Services/XPCService.swift MisttyTests/
git commit -m "feat: stable window IDs via window registry"
```
