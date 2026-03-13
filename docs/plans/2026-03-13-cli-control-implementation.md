# CLI Control & IPC Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add CLI control to Mistty via XPC IPC, enabling `mistty-cli` to manage sessions, tabs, panes, and windows.

**Architecture:** A shared Swift library (`MisttyShared`) defines the XPC protocol and Codable response types. The app starts an `NSXPCListener` on launch and implements the protocol by dispatching to `SessionStore`. A separate `mistty-cli` executable connects via XPC and exposes entity-based subcommands via Swift Argument Parser.

**Tech Stack:** Swift 6, NSXPCConnection, Swift Argument Parser, XCTest

---

### Task 1: Migrate model IDs from UUID to Int

Models currently use `let id = UUID()`. Change to atomic int IDs managed by SessionStore for CLI ergonomics.

**Files:**
- Modify: `Mistty/Models/SessionStore.swift`
- Modify: `Mistty/Models/MisttySession.swift`
- Modify: `Mistty/Models/MisttyTab.swift`
- Modify: `Mistty/Models/MisttyPane.swift`
- Modify: `MisttyTests/Models/SessionStoreTests.swift`

**Step 1: Update MisttySession to accept Int id**

In `Mistty/Models/MisttySession.swift`, change:
```swift
let id = UUID()
```
to:
```swift
let id: Int
```

Update the init to accept `id: Int`:
```swift
init(id: Int, name: String, directory: URL) {
    self.id = id
    self.name = name
    self.directory = directory
    addTab()
}
```

**Step 2: Update MisttyTab to accept Int id**

In `Mistty/Models/MisttyTab.swift`, change:
```swift
let id = UUID()
```
to:
```swift
let id: Int
```

This model has two initializers. Both need an `id: Int` parameter:
```swift
init(id: Int, directory: URL? = nil) {
    self.id = id
    self.directory = directory
    let pane = MisttyPane(id: 0) // placeholder — will be wired properly
    // ... rest unchanged
}

init(id: Int, existingPane pane: MisttyPane) {
    self.id = id
    // ... rest unchanged
}
```

Note: Tab creation is managed by MisttySession, so the id counter must flow from SessionStore through MisttySession. See step 4.

**Step 3: Update MisttyPane to accept Int id**

In `Mistty/Models/MisttyPane.swift`, change:
```swift
let id = UUID()
```
to:
```swift
let id: Int
```

Update init:
```swift
init(id: Int, directory: URL? = nil) {
    self.id = id
    self.directory = directory
}
```

Note: Panes are created inside MisttyTab (via `splitActivePane` and init). The id counter must flow from SessionStore through MisttySession and MisttyTab.

**Step 4: Add ID counters to SessionStore and thread them through**

In `Mistty/Models/SessionStore.swift`, add counters and an ID generator:
```swift
@Observable
@MainActor
final class SessionStore {
    private(set) var sessions: [MisttySession] = []
    var activeSession: MisttySession?

    private var nextSessionId = 1
    private var nextTabId = 1
    private var nextPaneId = 1

    func nextSessionID() -> Int {
        let id = nextSessionId
        nextSessionId += 1
        return id
    }

    func nextTabID() -> Int {
        let id = nextTabId
        nextTabId += 1
        return id
    }

    func nextPaneID() -> Int {
        let id = nextPaneId
        nextPaneId += 1
        return id
    }

    @discardableResult
    func createSession(name: String, directory: URL) -> MisttySession {
        let session = MisttySession(id: nextSessionID(), name: name, directory: directory, store: self)
        sessions.append(session)
        activeSession = session
        return session
    }

    func closeSession(_ session: MisttySession) {
        sessions.removeAll { $0.id == session.id }
        if activeSession?.id == session.id {
            activeSession = sessions.last
        }
    }
}
```

MisttySession needs a `store` reference to get IDs for new tabs/panes. Add a weak reference or pass an ID generator closure. The simplest approach: pass a reference to the store.

Update `MisttySession`:
```swift
@Observable
@MainActor
final class MisttySession: Identifiable {
    let id: Int
    var name: String
    let directory: URL
    private(set) var tabs: [MisttyTab] = []
    var activeTab: MisttyTab?
    private weak var store: SessionStore?

    init(id: Int, name: String, directory: URL, store: SessionStore) {
        self.id = id
        self.name = name
        self.directory = directory
        self.store = store
        addTab()
    }

    func addTab() {
        guard let store else { return }
        let paneId = store.nextPaneID()
        let tabId = store.nextTabID()
        let tab = MisttyTab(id: tabId, paneId: paneId, directory: directory)
        tabs.append(tab)
        activeTab = tab
    }

    func addTabWithPane(_ pane: MisttyPane) {
        guard let store else { return }
        let tabId = store.nextTabID()
        let tab = MisttyTab(id: tabId, existingPane: pane)
        tabs.append(tab)
        activeTab = tab
    }

    func closeTab(_ tab: MisttyTab) {
        tabs.removeAll { $0.id == tab.id }
        if activeTab?.id == tab.id {
            activeTab = tabs.last
        }
    }
}
```

Update `MisttyTab` to accept paneId for initial pane creation:
```swift
init(id: Int, paneId: Int, directory: URL? = nil) {
    self.id = id
    self.directory = directory
    let pane = MisttyPane(id: paneId, directory: directory)
    self.layout = PaneLayout(root: .leaf(pane))
    self.panes = [pane]
    self.activePane = pane
}
```

For `splitActivePane`, the tab needs access to the store's ID generator. Thread it through MisttySession → MisttyTab, or have MisttyTab hold a pane ID generator closure:

```swift
var paneIDGenerator: (() -> Int)?

func splitActivePane(direction: SplitDirection) {
    guard let activePane, let paneIDGenerator else { return }
    let newPaneId = paneIDGenerator()
    layout.split(pane: activePane, direction: direction, directory: directory, paneId: newPaneId)
    panes = layout.leaves
    self.activePane = panes.last
}
```

Wire in MisttySession's `addTab`:
```swift
func addTab() {
    guard let store else { return }
    let paneId = store.nextPaneID()
    let tabId = store.nextTabID()
    let tab = MisttyTab(id: tabId, paneId: paneId, directory: directory)
    tab.paneIDGenerator = { [weak store] in store?.nextPaneID() ?? 0 }
    tabs.append(tab)
    activeTab = tab
}
```

PaneLayout.split also needs updating — it currently creates a MisttyPane internally. Change it to accept a paneId parameter:

In `Mistty/Models/PaneLayout.swift`, update the split method signature:
```swift
mutating func split(pane: MisttyPane, direction: SplitDirection, directory: URL?, paneId: Int) {
    // Replace: let newPane = MisttyPane(directory: directory)
    // With:    let newPane = MisttyPane(id: paneId, directory: directory)
    // rest unchanged
}
```

**Step 5: Update tests**

Fix all test compilation errors. Tests that create MisttySession directly now need a SessionStore:
```swift
func testCreateSession() async throws {
    let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))
    XCTAssertEqual(session.id, 1)
    XCTAssertEqual(session.name, "test")
}
```

PaneLayoutTests that create MisttyPane directly need an id parameter:
```swift
let pane = MisttyPane(id: 1)
```

**Step 6: Run tests**

Run: `just test`
Expected: All tests pass with Int IDs.

**Step 7: Commit**

```bash
git add Mistty/Models/ MisttyTests/
git commit -m "refactor: migrate model IDs from UUID to Int for CLI ergonomics"
```

---

### Task 2: Create MisttyShared library with XPC protocol and response types

**Files:**
- Create: `MisttyShared/MisttyServiceProtocol.swift`
- Create: `MisttyShared/XPCConstants.swift`
- Create: `MisttyShared/Models/SessionResponse.swift`
- Create: `MisttyShared/Models/TabResponse.swift`
- Create: `MisttyShared/Models/PaneResponse.swift`
- Create: `MisttyShared/Models/WindowResponse.swift`
- Modify: `Package.swift`

**Step 1: Add MisttyShared target to Package.swift**

Add a library target with no dependencies:
```swift
.target(
    name: "MisttyShared",
    path: "MisttyShared"
),
```

Add MisttyShared as a dependency of the Mistty target:
```swift
.executableTarget(
    name: "Mistty",
    dependencies: ["GhosttyKit", "TOMLKit", "MisttyShared"],
    // ... rest unchanged
),
```

**Step 2: Create XPC constants**

`MisttyShared/XPCConstants.swift`:
```swift
import Foundation

public enum MisttyXPC {
    public static let serviceName = "com.mistty.cli-service"

    public enum ErrorCode: Int {
        case entityNotFound = 1
        case invalidArgument = 2
        case operationFailed = 3
    }

    public static let errorDomain = "com.mistty.error"

    public static func error(_ code: ErrorCode, _ message: String) -> NSError {
        NSError(domain: errorDomain, code: code.rawValue, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}
```

**Step 3: Create XPC protocol**

`MisttyShared/MisttyServiceProtocol.swift`:
```swift
import Foundation

@objc public protocol MisttyServiceProtocol {
    // Sessions
    func createSession(name: String, directory: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void)
    func listSessions(reply: @escaping (Data?, Error?) -> Void)
    func getSession(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func closeSession(id: Int, reply: @escaping (Data?, Error?) -> Void)

    // Tabs
    func createTab(sessionId: Int, name: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void)
    func listTabs(sessionId: Int, reply: @escaping (Data?, Error?) -> Void)
    func getTab(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func renameTab(id: Int, name: String, reply: @escaping (Data?, Error?) -> Void)

    // Panes
    func createPane(tabId: Int, direction: String?, reply: @escaping (Data?, Error?) -> Void)
    func listPanes(tabId: Int, reply: @escaping (Data?, Error?) -> Void)
    func getPane(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func closePane(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func focusPane(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func resizePane(id: Int, direction: String, amount: Int, reply: @escaping (Data?, Error?) -> Void)
    func activePane(reply: @escaping (Data?, Error?) -> Void)
    func sendKeys(paneId: Int, keys: String, reply: @escaping (Data?, Error?) -> Void)
    func runCommand(paneId: Int, command: String, reply: @escaping (Data?, Error?) -> Void)
    func getText(paneId: Int, reply: @escaping (Data?, Error?) -> Void)

    // Windows
    func createWindow(reply: @escaping (Data?, Error?) -> Void)
    func listWindows(reply: @escaping (Data?, Error?) -> Void)
    func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void)
}
```

Note: Using `Int` instead of `String` for IDs in the protocol since we migrated to Int IDs. XPC @objc supports Int natively.

Also note: `sendKeys`, `runCommand`, `getText` use non-optional `paneId: Int` here because @objc doesn't support optional value types. We'll use a sentinel value (0 or -1) to mean "active pane". The CLI will handle this mapping.

**Step 4: Create response types**

`MisttyShared/Models/SessionResponse.swift`:
```swift
import Foundation

public struct SessionResponse: Codable, Sendable {
    public let id: Int
    public let name: String
    public let directory: String
    public let tabCount: Int
    public let tabIds: [Int]

    public init(id: Int, name: String, directory: String, tabCount: Int, tabIds: [Int]) {
        self.id = id
        self.name = name
        self.directory = directory
        self.tabCount = tabCount
        self.tabIds = tabIds
    }
}
```

`MisttyShared/Models/TabResponse.swift`:
```swift
import Foundation

public struct TabResponse: Codable, Sendable {
    public let id: Int
    public let title: String
    public let paneCount: Int
    public let paneIds: [Int]

    public init(id: Int, title: String, paneCount: Int, paneIds: [Int]) {
        self.id = id
        self.title = title
        self.paneCount = paneCount
        self.paneIds = paneIds
    }
}
```

`MisttyShared/Models/PaneResponse.swift`:
```swift
import Foundation

public struct PaneResponse: Codable, Sendable {
    public let id: Int
    public let directory: String?

    public init(id: Int, directory: String?) {
        self.id = id
        self.directory = directory
    }
}
```

`MisttyShared/Models/WindowResponse.swift`:
```swift
import Foundation

public struct WindowResponse: Codable, Sendable {
    public let id: Int
    public let sessionCount: Int

    public init(id: Int, sessionCount: Int) {
        self.id = id
        self.sessionCount = sessionCount
    }
}
```

**Step 5: Verify build**

Run: `swift build`
Expected: Compiles with no errors.

**Step 6: Commit**

```bash
git add MisttyShared/ Package.swift
git commit -m "feat: add MisttyShared library with XPC protocol and response types"
```

---

### Task 3: Implement XPC listener in the app

**Files:**
- Create: `Mistty/Services/XPCListener.swift`
- Modify: `Mistty/App/MisttyApp.swift`

**Step 1: Create XPCListener**

`Mistty/Services/XPCListener.swift`:
```swift
import Foundation
import MisttyShared

@MainActor
final class MisttyXPCListener: NSObject {
    private var listener: NSXPCListener?
    private let service: MisttyServiceProtocol

    init(service: MisttyServiceProtocol) {
        self.service = service
        super.init()
    }

    func start() {
        let listener = NSXPCListener(machServiceName: MisttyXPC.serviceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    func stop() {
        listener?.invalidate()
        listener = nil
    }
}

extension MisttyXPCListener: NSXPCListenerDelegate {
    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: MisttyServiceProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}
```

**Step 2: Create a stub XPC service for now**

`Mistty/Services/XPCService.swift`:
```swift
import Foundation
import MisttyShared

@MainActor
final class MisttyXPCService: NSObject, MisttyServiceProtocol {
    let store: SessionStore

    init(store: SessionStore) {
        self.store = store
        super.init()
    }

    // Stub implementations — will be filled in Task 4
    nonisolated func createSession(name: String, directory: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func listSessions(reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func getSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func closeSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func createTab(sessionId: Int, name: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func listTabs(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func getTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func renameTab(id: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func createPane(tabId: Int, direction: String?, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func listPanes(tabId: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func getPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func closePane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func focusPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func resizePane(id: Int, direction: String, amount: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func activePane(reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func sendKeys(paneId: Int, keys: String, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func runCommand(paneId: Int, command: String, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func getText(paneId: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func createWindow(reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func listWindows(reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
    nonisolated func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
    }
}
```

**Step 3: Wire listener into MisttyApp**

In `Mistty/App/MisttyApp.swift`, the ContentView already creates a SessionStore via `@State`. The XPC listener needs access to the same store. Move store ownership to the App level or pass it down.

The cleanest approach: ContentView already has `@State var store = SessionStore()`. We need the listener to start with the same store. Add an `onAppear` in ContentView that starts the listener:

In `Mistty/App/ContentView.swift`, add:
```swift
@State private var xpcListener: MisttyXPCListener?

// In body, add to the root view:
.onAppear {
    let service = MisttyXPCService(store: store)
    let listener = MisttyXPCListener(service: service)
    listener.start()
    xpcListener = listener
}
```

**Step 4: Verify build**

Run: `swift build`
Expected: Compiles. The listener won't actually work without a launchd plist, but the code should compile.

**Step 5: Commit**

```bash
git add Mistty/Services/XPCListener.swift Mistty/Services/XPCService.swift Mistty/App/ContentView.swift
git commit -m "feat: add XPC listener and stub service for CLI control"
```

---

### Task 4: Implement XPC service — session operations

**Files:**
- Modify: `Mistty/Services/XPCService.swift`
- Modify: `Mistty/Models/SessionStore.swift` (add lookup helpers)
- Test: `MisttyTests/Services/XPCServiceTests.swift`

**Step 1: Add lookup helpers to SessionStore**

In `Mistty/Models/SessionStore.swift`, add:
```swift
func session(byId id: Int) -> MisttySession? {
    sessions.first { $0.id == id }
}

func tab(byId id: Int) -> (session: MisttySession, tab: MisttyTab)? {
    for session in sessions {
        if let tab = session.tabs.first(where: { $0.id == id }) {
            return (session, tab)
        }
    }
    return nil
}

func pane(byId id: Int) -> (session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    for session in sessions {
        for tab in session.tabs {
            if let pane = tab.panes.first(where: { $0.id == id }) {
                return (session, tab, pane)
            }
        }
    }
    return nil
}

func activePaneInfo() -> (session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    guard let session = activeSession,
          let tab = session.activeTab,
          let pane = tab.activePane else { return nil }
    return (session, tab, pane)
}
```

**Step 2: Write tests for session operations**

`MisttyTests/Services/XPCServiceTests.swift`:
```swift
@testable import Mistty
import MisttyShared
import XCTest

@MainActor
final class XPCServiceTests: XCTestCase {
    var store: SessionStore!
    var service: MisttyXPCService!

    override func setUp() async throws {
        store = SessionStore()
        service = MisttyXPCService(store: store)
    }

    // MARK: - Session tests

    func testCreateSession() async throws {
        let expectation = XCTestExpectation(description: "create session")
        service.createSession(name: "test", directory: "/tmp", exec: nil) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let response = try! JSONDecoder().decode(SessionResponse.self, from: data!)
            XCTAssertEqual(response.name, "test")
            XCTAssertEqual(response.directory, "/tmp")
            XCTAssertEqual(response.tabCount, 1)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testListSessions() async throws {
        store.createSession(name: "s1", directory: URL(filePath: "/tmp"))
        store.createSession(name: "s2", directory: URL(filePath: "/tmp"))

        let expectation = XCTestExpectation(description: "list sessions")
        service.listSessions { data, error in
            XCTAssertNil(error)
            let sessions = try! JSONDecoder().decode([SessionResponse].self, from: data!)
            XCTAssertEqual(sessions.count, 2)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testGetSession() async throws {
        let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))

        let expectation = XCTestExpectation(description: "get session")
        service.getSession(id: session.id) { data, error in
            XCTAssertNil(error)
            let response = try! JSONDecoder().decode(SessionResponse.self, from: data!)
            XCTAssertEqual(response.name, "test")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testGetSessionNotFound() async throws {
        let expectation = XCTestExpectation(description: "get session not found")
        service.getSession(id: 999) { data, error in
            XCTAssertNil(data)
            XCTAssertNotNil(error)
            XCTAssertEqual((error! as NSError).code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testCloseSession() async throws {
        let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))

        let expectation = XCTestExpectation(description: "close session")
        service.closeSession(id: session.id) { data, error in
            XCTAssertNil(error)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertTrue(store.sessions.isEmpty)
    }
}
```

**Step 3: Run tests to verify they fail**

Run: `just test`
Expected: FAIL — stub implementations return "Not implemented" errors.

**Step 4: Implement session operations in XPCService**

Replace the session stubs in `Mistty/Services/XPCService.swift`:

```swift
nonisolated func createSession(name: String, directory: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        let dir = URL(filePath: directory ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let session = store.createSession(name: name, directory: dir)
        let response = SessionResponse(
            id: session.id,
            name: session.name,
            directory: session.directory.path,
            tabCount: session.tabs.count,
            tabIds: session.tabs.map(\.id)
        )
        reply(try? JSONEncoder().encode(response), nil)
    }
}

nonisolated func listSessions(reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        let responses = store.sessions.map { session in
            SessionResponse(
                id: session.id,
                name: session.name,
                directory: session.directory.path,
                tabCount: session.tabs.count,
                tabIds: session.tabs.map(\.id)
            )
        }
        reply(try? JSONEncoder().encode(responses), nil)
    }
}

nonisolated func getSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let session = store.session(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Session \(id) not found"))
            return
        }
        let response = SessionResponse(
            id: session.id,
            name: session.name,
            directory: session.directory.path,
            tabCount: session.tabs.count,
            tabIds: session.tabs.map(\.id)
        )
        reply(try? JSONEncoder().encode(response), nil)
    }
}

nonisolated func closeSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let session = store.session(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Session \(id) not found"))
            return
        }
        store.closeSession(session)
        reply(Data("{}".utf8), nil)
    }
}
```

**Step 5: Run tests**

Run: `just test`
Expected: Session tests pass.

**Step 6: Commit**

```bash
git add Mistty/Services/XPCService.swift Mistty/Models/SessionStore.swift MisttyTests/Services/XPCServiceTests.swift
git commit -m "feat: implement XPC service session operations with tests"
```

---

### Task 5: Implement XPC service — tab operations

**Files:**
- Modify: `Mistty/Services/XPCService.swift`
- Modify: `MisttyTests/Services/XPCServiceTests.swift`

**Step 1: Write tab operation tests**

Add to `MisttyTests/Services/XPCServiceTests.swift`:
```swift
// MARK: - Tab tests

func testCreateTab() async throws {
    let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))
    let initialTabCount = session.tabs.count

    let expectation = XCTestExpectation(description: "create tab")
    service.createTab(sessionId: session.id, name: "new tab", exec: nil) { data, error in
        XCTAssertNil(error)
        let response = try! JSONDecoder().decode(TabResponse.self, from: data!)
        XCTAssertEqual(response.title, "new tab")
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
    XCTAssertEqual(session.tabs.count, initialTabCount + 1)
}

func testListTabs() async throws {
    let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))
    session.addTab() // now 2 tabs

    let expectation = XCTestExpectation(description: "list tabs")
    service.listTabs(sessionId: session.id) { data, error in
        XCTAssertNil(error)
        let tabs = try! JSONDecoder().decode([TabResponse].self, from: data!)
        XCTAssertEqual(tabs.count, 2)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}

func testCloseTab() async throws {
    let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))
    let tabId = session.tabs.first!.id

    let expectation = XCTestExpectation(description: "close tab")
    service.closeTab(id: tabId) { data, error in
        XCTAssertNil(error)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
    XCTAssertTrue(session.tabs.isEmpty)
}

func testRenameTab() async throws {
    let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))
    let tabId = session.tabs.first!.id

    let expectation = XCTestExpectation(description: "rename tab")
    service.renameTab(id: tabId, name: "renamed") { data, error in
        XCTAssertNil(error)
        let response = try! JSONDecoder().decode(TabResponse.self, from: data!)
        XCTAssertEqual(response.title, "renamed")
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}
```

**Step 2: Run tests to verify they fail**

Run: `just test`
Expected: FAIL — tab stubs return "Not implemented".

**Step 3: Implement tab operations**

Replace tab stubs in `Mistty/Services/XPCService.swift`:

```swift
nonisolated func createTab(sessionId: Int, name: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let session = store.session(byId: sessionId) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Session \(sessionId) not found"))
            return
        }
        session.addTab()
        guard let tab = session.tabs.last else {
            reply(nil, MisttyXPC.error(.operationFailed, "Failed to create tab"))
            return
        }
        if let name { tab.customTitle = name }
        let response = TabResponse(
            id: tab.id,
            title: tab.displayTitle,
            paneCount: tab.panes.count,
            paneIds: tab.panes.map(\.id)
        )
        reply(try? JSONEncoder().encode(response), nil)
    }
}

nonisolated func listTabs(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let session = store.session(byId: sessionId) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Session \(sessionId) not found"))
            return
        }
        let responses = session.tabs.map { tab in
            TabResponse(id: tab.id, title: tab.displayTitle, paneCount: tab.panes.count, paneIds: tab.panes.map(\.id))
        }
        reply(try? JSONEncoder().encode(responses), nil)
    }
}

nonisolated func getTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (_, tab) = store.tab(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(id) not found"))
            return
        }
        let response = TabResponse(id: tab.id, title: tab.displayTitle, paneCount: tab.panes.count, paneIds: tab.panes.map(\.id))
        reply(try? JSONEncoder().encode(response), nil)
    }
}

nonisolated func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (session, tab) = store.tab(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(id) not found"))
            return
        }
        session.closeTab(tab)
        reply(Data("{}".utf8), nil)
    }
}

nonisolated func renameTab(id: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (_, tab) = store.tab(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(id) not found"))
            return
        }
        tab.customTitle = name
        let response = TabResponse(id: tab.id, title: tab.displayTitle, paneCount: tab.panes.count, paneIds: tab.panes.map(\.id))
        reply(try? JSONEncoder().encode(response), nil)
    }
}
```

**Step 4: Run tests**

Run: `just test`
Expected: All tab tests pass.

**Step 5: Commit**

```bash
git add Mistty/Services/XPCService.swift MisttyTests/Services/XPCServiceTests.swift
git commit -m "feat: implement XPC service tab operations with tests"
```

---

### Task 6: Implement XPC service — pane operations

**Files:**
- Modify: `Mistty/Services/XPCService.swift`
- Modify: `MisttyTests/Services/XPCServiceTests.swift`

**Step 1: Write pane operation tests**

Add to `MisttyTests/Services/XPCServiceTests.swift`:
```swift
// MARK: - Pane tests

func testListPanes() async throws {
    let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))
    let tabId = session.tabs.first!.id

    let expectation = XCTestExpectation(description: "list panes")
    service.listPanes(tabId: tabId) { data, error in
        XCTAssertNil(error)
        let panes = try! JSONDecoder().decode([PaneResponse].self, from: data!)
        XCTAssertEqual(panes.count, 1)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}

func testActivePane() async throws {
    let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))
    let expectedPaneId = session.activeTab!.activePane!.id

    let expectation = XCTestExpectation(description: "active pane")
    service.activePane { data, error in
        XCTAssertNil(error)
        let pane = try! JSONDecoder().decode(PaneResponse.self, from: data!)
        XCTAssertEqual(pane.id, expectedPaneId)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}

func testClosePane() async throws {
    let session = store.createSession(name: "test", directory: URL(filePath: "/tmp"))
    let tab = session.tabs.first!
    tab.splitActivePane(direction: .horizontal) // now 2 panes
    let paneToClose = tab.panes.last!

    let expectation = XCTestExpectation(description: "close pane")
    service.closePane(id: paneToClose.id) { data, error in
        XCTAssertNil(error)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
    XCTAssertEqual(tab.panes.count, 1)
}

func testGetPaneNotFound() async throws {
    let expectation = XCTestExpectation(description: "pane not found")
    service.getPane(id: 999) { data, error in
        XCTAssertNotNil(error)
        XCTAssertEqual((error! as NSError).code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}
```

**Step 2: Run tests to verify they fail**

Run: `just test`
Expected: FAIL.

**Step 3: Implement pane operations**

Replace pane stubs in `Mistty/Services/XPCService.swift`:

```swift
nonisolated func createPane(tabId: Int, direction: String?, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (_, tab) = store.tab(byId: tabId) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(tabId) not found"))
            return
        }
        let splitDir: SplitDirection = direction == "vertical" ? .vertical : .horizontal
        tab.splitActivePane(direction: splitDir)
        guard let pane = tab.panes.last else {
            reply(nil, MisttyXPC.error(.operationFailed, "Failed to create pane"))
            return
        }
        let response = PaneResponse(id: pane.id, directory: pane.directory?.path)
        reply(try? JSONEncoder().encode(response), nil)
    }
}

nonisolated func listPanes(tabId: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (_, tab) = store.tab(byId: tabId) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(tabId) not found"))
            return
        }
        let responses = tab.panes.map { PaneResponse(id: $0.id, directory: $0.directory?.path) }
        reply(try? JSONEncoder().encode(responses), nil)
    }
}

nonisolated func getPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (_, _, pane) = store.pane(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(id) not found"))
            return
        }
        let response = PaneResponse(id: pane.id, directory: pane.directory?.path)
        reply(try? JSONEncoder().encode(response), nil)
    }
}

nonisolated func closePane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (_, tab, pane) = store.pane(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(id) not found"))
            return
        }
        tab.closePane(pane)
        reply(Data("{}".utf8), nil)
    }
}

nonisolated func focusPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (session, tab, pane) = store.pane(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(id) not found"))
            return
        }
        store.activeSession = session
        session.activeTab = tab
        tab.activePane = pane
        let response = PaneResponse(id: pane.id, directory: pane.directory?.path)
        reply(try? JSONEncoder().encode(response), nil)
    }
}

nonisolated func resizePane(id: Int, direction: String, amount: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (_, tab, pane) = store.pane(byId: id) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(id) not found"))
            return
        }
        let delta = CGFloat(amount) / 100.0 // normalize to ratio
        let splitDir: SplitDirection? = switch direction {
            case "left", "right": .horizontal
            case "up", "down": .vertical
            default: nil
        }
        let sign: CGFloat = (direction == "right" || direction == "down") ? 1.0 : -1.0
        tab.layout.resizeSplit(containing: pane, delta: delta * sign, along: splitDir)
        reply(Data("{}".utf8), nil)
    }
}

nonisolated func activePane(reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        guard let (_, _, pane) = store.activePaneInfo() else {
            reply(nil, MisttyXPC.error(.entityNotFound, "No active pane"))
            return
        }
        let response = PaneResponse(id: pane.id, directory: pane.directory?.path)
        reply(try? JSONEncoder().encode(response), nil)
    }
}

nonisolated func sendKeys(paneId: Int, keys: String, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        let targetPane: MisttyPane?
        if paneId <= 0 {
            targetPane = store.activePaneInfo()?.pane
        } else {
            targetPane = store.pane(byId: paneId)?.pane
        }
        guard let pane = targetPane else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Pane not found"))
            return
        }
        // Send keys by simulating keyboard input to the ghostty surface
        let view = pane.surfaceView
        guard let surface = view.surface else {
            reply(nil, MisttyXPC.error(.operationFailed, "Pane has no active surface"))
            return
        }
        // Use ghostty_surface_text to send text input
        keys.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(keys.utf8.count))
        }
        reply(Data("{}".utf8), nil)
    }
}

nonisolated func runCommand(paneId: Int, command: String, reply: @escaping (Data?, Error?) -> Void) {
    // Append newline and delegate to sendKeys
    sendKeys(paneId: paneId, keys: command + "\n", reply: reply)
}

nonisolated func getText(paneId: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor [store] in
        let targetPane: MisttyPane?
        if paneId <= 0 {
            targetPane = store.activePaneInfo()?.pane
        } else {
            targetPane = store.pane(byId: paneId)?.pane
        }
        guard let pane = targetPane else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Pane not found"))
            return
        }
        let view = pane.surfaceView
        guard let surface = view.surface else {
            reply(nil, MisttyXPC.error(.operationFailed, "Pane has no active surface"))
            return
        }
        // Read visible terminal text using ghostty API
        // ghostty_surface_read_text returns the screen content
        var text: UnsafeMutablePointer<CChar>?
        var len: Int = 0
        // Note: exact API depends on ghostty version — may need adjustment
        let screenText = "" // Placeholder: implement using ghostty_surface_inspector or similar
        let data = try? JSONEncoder().encode(["text": screenText])
        reply(data, nil)
    }
}
```

Note on `sendKeys` and `getText`: These interact with the ghostty C API. The exact function signatures (`ghostty_surface_text`, reading screen content) may need adjustment based on the actual ghostty API available. Check `TerminalSurfaceView.swift` for patterns — `insertText` and copy mode's screen reading logic show how to interact with the surface.

**Step 4: Run tests**

Run: `just test`
Expected: Pane tests pass. `sendKeys`/`getText` tests may need mocking or integration testing since they touch ghostty surfaces.

**Step 5: Commit**

```bash
git add Mistty/Services/XPCService.swift MisttyTests/Services/XPCServiceTests.swift
git commit -m "feat: implement XPC service pane operations with tests"
```

---

### Task 7: Implement XPC service — window operations

**Files:**
- Modify: `Mistty/Services/XPCService.swift`
- Modify: `MisttyTests/Services/XPCServiceTests.swift`

Window management in macOS SwiftUI uses `NSApplication.shared.windows`. Since Mistty uses a single `WindowGroup`, windows are tracked by the system. We need a lightweight model to expose them via XPC.

**Step 1: Write window tests**

Add to `MisttyTests/Services/XPCServiceTests.swift`:
```swift
// MARK: - Window tests

func testListWindows() async throws {
    let expectation = XCTestExpectation(description: "list windows")
    service.listWindows { data, error in
        XCTAssertNil(error)
        XCTAssertNotNil(data)
        expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 2)
}
```

**Step 2: Implement window operations**

Window operations interact with `NSApplication.shared.windows` on the main thread. Replace stubs:

```swift
nonisolated func createWindow(reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor in
        // Post notification or use NSApp to open new window
        // SwiftUI WindowGroup handles window creation via openWindow
        reply(nil, MisttyXPC.error(.operationFailed, "Window creation requires SwiftUI environment — use session create instead"))
    }
}

nonisolated func listWindows(reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor in
        let windows = NSApplication.shared.windows.filter { $0.isVisible }
        let responses = windows.enumerated().map { (index, window) in
            WindowResponse(id: index + 1, sessionCount: 0)
        }
        reply(try? JSONEncoder().encode(responses), nil)
    }
}

nonisolated func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor in
        let windows = NSApplication.shared.windows.filter { $0.isVisible }
        guard id >= 1, id <= windows.count else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Window \(id) not found"))
            return
        }
        let response = WindowResponse(id: id, sessionCount: 0)
        reply(try? JSONEncoder().encode(response), nil)
    }
}

nonisolated func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor in
        let windows = NSApplication.shared.windows.filter { $0.isVisible }
        guard id >= 1, id <= windows.count else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Window \(id) not found"))
            return
        }
        windows[id - 1].close()
        reply(Data("{}".utf8), nil)
    }
}

nonisolated func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    Task { @MainActor in
        let windows = NSApplication.shared.windows.filter { $0.isVisible }
        guard id >= 1, id <= windows.count else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Window \(id) not found"))
            return
        }
        windows[id - 1].makeKeyAndOrderFront(nil)
        reply(Data("{}".utf8), nil)
    }
}
```

Note: Window IDs here are positional (1-indexed into visible windows). This is a pragmatic approach since SwiftUI's `WindowGroup` doesn't expose stable window identifiers. If multi-window becomes more important later, we can add a proper window registry.

**Step 3: Run tests**

Run: `just test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add Mistty/Services/XPCService.swift MisttyTests/Services/XPCServiceTests.swift
git commit -m "feat: implement XPC service window operations"
```

---

### Task 8: Create MisttyCLI executable target

**Files:**
- Modify: `Package.swift`
- Create: `MisttyCLI/MisttyCLI.swift`
- Create: `MisttyCLI/XPCClient.swift`
- Create: `MisttyCLI/OutputFormatter.swift`

**Step 1: Add swift-argument-parser dependency and CLI target to Package.swift**

Add to dependencies array:
```swift
.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
```

Add new executable target:
```swift
.executableTarget(
    name: "MisttyCLI",
    dependencies: [
        "MisttyShared",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ],
    path: "MisttyCLI"
),
```

**Step 2: Create XPC client with auto-launch and retry**

`MisttyCLI/XPCClient.swift`:
```swift
import Foundation
import MisttyShared

final class XPCClient {
    private var connection: NSXPCConnection?

    func connect() throws -> MisttyServiceProtocol {
        if let connection, let proxy = connection.remoteObjectProxy as? MisttyServiceProtocol {
            return proxy
        }

        // Try to connect
        for attempt in 0..<5 {
            let conn = NSXPCConnection(machServiceName: MisttyXPC.serviceName)
            conn.remoteObjectInterface = NSXPCInterface(with: MisttyServiceProtocol.self)
            conn.resume()

            // Test connection with a simple call
            let semaphore = DispatchSemaphore(value: 0)
            var connected = false

            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                semaphore.signal()
            } as! MisttyServiceProtocol

            proxy.listSessions { _, error in
                connected = error == nil || (error as? NSError)?.domain == MisttyXPC.errorDomain
                semaphore.signal()
            }

            let timeout = DispatchTime.now() + .milliseconds(500)
            if semaphore.wait(timeout: timeout) == .success, connected {
                self.connection = conn
                return proxy
            }

            conn.invalidate()

            // Launch app on first failure
            if attempt == 0 {
                launchApp()
            }

            // Exponential backoff: 100, 200, 400, 800ms
            let delay = UInt32(100_000 * (1 << attempt)) // microseconds
            usleep(delay)
        }

        throw MisttyXPC.error(.operationFailed, "Could not connect to Mistty.app. Is it installed?")
    }

    private func launchApp() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-a", "Mistty"]
        try? process.run()
    }

    func proxy() throws -> MisttyServiceProtocol {
        try connect()
    }
}
```

**Step 3: Create output formatter**

`MisttyCLI/OutputFormatter.swift`:
```swift
import Foundation

enum OutputFormat {
    case human
    case json

    static func detect(forceJSON: Bool, forceHuman: Bool) -> OutputFormat {
        if forceJSON { return .json }
        if forceHuman { return .human }
        return isatty(STDOUT_FILENO) != 0 ? .human : .json
    }
}

struct OutputFormatter {
    let format: OutputFormat

    func printJSON(_ data: Data) {
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    func printTable(headers: [String], rows: [[String]]) {
        guard !rows.isEmpty else {
            print("(none)")
            return
        }

        // Calculate column widths
        var widths = headers.map(\.count)
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        // Print header
        let headerLine = zip(headers, widths).map { $0.0.padding(toLength: $0.1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
        print(headerLine)

        // Print rows
        for row in rows {
            let line = zip(row, widths).map { $0.0.padding(toLength: $0.1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
            print(line)
        }
    }

    func printSingle(_ pairs: [(String, String)]) {
        let maxKey = pairs.map(\.0.count).max() ?? 0
        for (key, value) in pairs {
            print("\(key.padding(toLength: maxKey, withPad: " ", startingAt: 0))  \(value)")
        }
    }

    func printSuccess(_ message: String = "OK") {
        if format == .json {
            print("{}")
        } else {
            print(message)
        }
    }

    func printError(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }
}
```

**Step 4: Create CLI entry point**

`MisttyCLI/MisttyCLI.swift`:
```swift
import ArgumentParser
import Foundation
import MisttyShared

@main
struct MisttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mistty-cli",
        abstract: "Control Mistty terminal emulator",
        subcommands: [
            SessionCommand.self,
            TabCommand.self,
            PaneCommand.self,
            WindowCommand.self,
        ]
    )
}
```

**Step 5: Verify it builds**

Run: `swift build --target MisttyCLI`
Expected: Compiles (commands are empty stubs for now).

**Step 6: Commit**

```bash
git add Package.swift MisttyCLI/
git commit -m "feat: add MisttyCLI executable target with XPC client and output formatter"
```

---

### Task 9: Implement CLI session commands

**Files:**
- Create: `MisttyCLI/Commands/SessionCommand.swift`

**Step 1: Implement session subcommands**

`MisttyCLI/Commands/SessionCommand.swift`:
```swift
import ArgumentParser
import Foundation
import MisttyShared

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage sessions",
        subcommands: [Create.self, List.self, Get.self, Close.self]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new session")

        @Option(name: .long, help: "Session name")
        var name: String

        @Option(name: .long, help: "Working directory")
        var directory: String?

        @Option(name: .long, help: "Command to execute in first pane")
        var exec: String?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.createSession(name: name, directory: directory, exec: exec) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode(SessionResponse.self, from: data)
                    formatter.printSingle([
                        ("ID:", "\(response.id)"),
                        ("Name:", response.name),
                        ("Directory:", response.directory),
                        ("Tabs:", "\(response.tabCount)"),
                    ])
                }
            }
            semaphore.wait()
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all sessions")

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.listSessions { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let sessions = try! JSONDecoder().decode([SessionResponse].self, from: data)
                    formatter.printTable(
                        headers: ["ID", "NAME", "TABS", "DIRECTORY"],
                        rows: sessions.map { ["\($0.id)", $0.name, "\($0.tabCount)", $0.directory] }
                    )
                }
            }
            semaphore.wait()
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get session details")

        @Argument(help: "Session ID")
        var id: Int

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.getSession(id: id) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode(SessionResponse.self, from: data)
                    formatter.printSingle([
                        ("ID:", "\(response.id)"),
                        ("Name:", response.name),
                        ("Directory:", response.directory),
                        ("Tabs:", "\(response.tabCount)"),
                        ("Tab IDs:", response.tabIds.map(String.init).joined(separator: ", ")),
                    ])
                }
            }
            semaphore.wait()
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a session")

        @Argument(help: "Session ID")
        var id: Int

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.closeSession(id: id) { _, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                formatter.printSuccess("Session \(id) closed")
            }
            semaphore.wait()
        }
    }
}
```

**Step 2: Build**

Run: `swift build --target MisttyCLI`
Expected: Compiles.

**Step 3: Commit**

```bash
git add MisttyCLI/Commands/SessionCommand.swift
git commit -m "feat: implement CLI session commands (create, list, get, close)"
```

---

### Task 10: Implement CLI tab commands

**Files:**
- Create: `MisttyCLI/Commands/TabCommand.swift`

**Step 1: Implement tab subcommands**

`MisttyCLI/Commands/TabCommand.swift`:
```swift
import ArgumentParser
import Foundation
import MisttyShared

struct TabCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Manage tabs",
        subcommands: [Create.self, List.self, Get.self, Close.self, Rename.self]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new tab")

        @Option(name: .long, help: "Session ID")
        var session: Int

        @Option(name: .long, help: "Tab name")
        var name: String?

        @Option(name: .long, help: "Command to execute")
        var exec: String?

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.createTab(sessionId: session, name: name, exec: exec) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode(TabResponse.self, from: data)
                    formatter.printSingle([
                        ("ID:", "\(response.id)"),
                        ("Title:", response.title),
                        ("Panes:", "\(response.paneCount)"),
                    ])
                }
            }
            semaphore.wait()
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List tabs in a session")

        @Option(name: .long, help: "Session ID")
        var session: Int

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.listTabs(sessionId: session) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let tabs = try! JSONDecoder().decode([TabResponse].self, from: data)
                    formatter.printTable(
                        headers: ["ID", "TITLE", "PANES"],
                        rows: tabs.map { ["\($0.id)", $0.title, "\($0.paneCount)"] }
                    )
                }
            }
            semaphore.wait()
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get tab details")

        @Argument(help: "Tab ID")
        var id: Int

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.getTab(id: id) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode(TabResponse.self, from: data)
                    formatter.printSingle([
                        ("ID:", "\(response.id)"),
                        ("Title:", response.title),
                        ("Panes:", "\(response.paneCount)"),
                        ("Pane IDs:", response.paneIds.map(String.init).joined(separator: ", ")),
                    ])
                }
            }
            semaphore.wait()
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a tab")

        @Argument(help: "Tab ID")
        var id: Int

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.closeTab(id: id) { _, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                formatter.printSuccess("Tab \(id) closed")
            }
            semaphore.wait()
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a tab")

        @Argument(help: "Tab ID")
        var id: Int

        @Option(name: .long, help: "New name")
        var name: String

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.renameTab(id: id, name: name) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode(TabResponse.self, from: data)
                    formatter.printSingle([
                        ("ID:", "\(response.id)"),
                        ("Title:", response.title),
                    ])
                }
            }
            semaphore.wait()
        }
    }
}
```

**Step 2: Build**

Run: `swift build --target MisttyCLI`
Expected: Compiles.

**Step 3: Commit**

```bash
git add MisttyCLI/Commands/TabCommand.swift
git commit -m "feat: implement CLI tab commands (create, list, get, close, rename)"
```

---

### Task 11: Implement CLI pane commands

**Files:**
- Create: `MisttyCLI/Commands/PaneCommand.swift`

**Step 1: Implement pane subcommands**

`MisttyCLI/Commands/PaneCommand.swift`:
```swift
import ArgumentParser
import Foundation
import MisttyShared

struct PaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Manage panes",
        subcommands: [
            Create.self, List.self, Get.self, Close.self,
            Focus.self, Resize.self, Active.self,
            SendKeys.self, RunCommand.self, GetText.self,
        ]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Split to create a new pane")

        @Option(name: .long, help: "Tab ID")
        var tab: Int

        @Option(name: .long, help: "Split direction: horizontal or vertical")
        var direction: String?

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.createPane(tabId: tab, direction: direction) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode(PaneResponse.self, from: data)
                    formatter.printSingle([
                        ("ID:", "\(response.id)"),
                        ("Directory:", response.directory ?? "(none)"),
                    ])
                }
            }
            semaphore.wait()
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List panes in a tab")

        @Option(name: .long, help: "Tab ID")
        var tab: Int

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.listPanes(tabId: tab) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let panes = try! JSONDecoder().decode([PaneResponse].self, from: data)
                    formatter.printTable(
                        headers: ["ID", "DIRECTORY"],
                        rows: panes.map { ["\($0.id)", $0.directory ?? "(none)"] }
                    )
                }
            }
            semaphore.wait()
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get pane details")

        @Argument(help: "Pane ID")
        var id: Int

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.getPane(id: id) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode(PaneResponse.self, from: data)
                    formatter.printSingle([
                        ("ID:", "\(response.id)"),
                        ("Directory:", response.directory ?? "(none)"),
                    ])
                }
            }
            semaphore.wait()
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a pane")

        @Argument(help: "Pane ID")
        var id: Int

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.closePane(id: id) { _, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                formatter.printSuccess("Pane \(id) closed")
            }
            semaphore.wait()
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Focus a pane")

        @Argument(help: "Pane ID")
        var id: Int

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.focusPane(id: id) { _, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                formatter.printSuccess("Focused pane \(id)")
            }
            semaphore.wait()
        }
    }

    struct Resize: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resize a pane")

        @Argument(help: "Pane ID")
        var id: Int

        @Option(name: .long, help: "Direction: left, right, up, down")
        var direction: String

        @Option(name: .long, help: "Resize amount (default 5)")
        var amount: Int = 5

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.resizePane(id: id, direction: direction, amount: amount) { _, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                formatter.printSuccess("Resized pane \(id)")
            }
            semaphore.wait()
        }
    }

    struct Active: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get the active pane")

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.activePane { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode(PaneResponse.self, from: data)
                    formatter.printSingle([
                        ("ID:", "\(response.id)"),
                        ("Directory:", response.directory ?? "(none)"),
                    ])
                }
            }
            semaphore.wait()
        }
    }

    struct SendKeys: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "send-keys",
            abstract: "Send keystrokes to a pane"
        )

        @Option(name: .long, help: "Pane ID (default: active pane)")
        var pane: Int = 0

        @Argument(help: "Keys to send")
        var keys: String

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.sendKeys(paneId: pane, keys: keys) { _, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
            }
            semaphore.wait()
        }
    }

    struct RunCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run-command",
            abstract: "Run a command in a pane (sends text + enter)"
        )

        @Option(name: .long, help: "Pane ID (default: active pane)")
        var pane: Int = 0

        @Argument(help: "Command to run")
        var command: String

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.runCommand(paneId: pane, command: command) { _, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
            }
            semaphore.wait()
        }
    }

    struct GetText: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-text",
            abstract: "Get visible text from a pane"
        )

        @Option(name: .long, help: "Pane ID (default: active pane)")
        var pane: Int = 0

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.getText(paneId: pane) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode([String: String].self, from: data)
                    print(response["text"] ?? "")
                }
            }
            semaphore.wait()
        }
    }
}
```

**Step 2: Build**

Run: `swift build --target MisttyCLI`
Expected: Compiles.

**Step 3: Commit**

```bash
git add MisttyCLI/Commands/PaneCommand.swift
git commit -m "feat: implement CLI pane commands (create, list, get, close, focus, resize, active, send-keys, run-command, get-text)"
```

---

### Task 12: Implement CLI window commands

**Files:**
- Create: `MisttyCLI/Commands/WindowCommand.swift`

**Step 1: Implement window subcommands**

`MisttyCLI/Commands/WindowCommand.swift`:
```swift
import ArgumentParser
import Foundation
import MisttyShared

struct WindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "Manage windows",
        subcommands: [Create.self, List.self, Get.self, Close.self, Focus.self]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new window")

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.createWindow { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                formatter.printJSON(data)
            }
            semaphore.wait()
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List windows")

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.listWindows { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let windows = try! JSONDecoder().decode([WindowResponse].self, from: data)
                    formatter.printTable(
                        headers: ["ID", "SESSIONS"],
                        rows: windows.map { ["\($0.id)", "\($0.sessionCount)"] }
                    )
                }
            }
            semaphore.wait()
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get window details")

        @Argument(help: "Window ID")
        var id: Int

        @Flag(name: .long) var json = false
        @Flag(name: .long) var human = false

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: json, forceHuman: human))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.getWindow(id: id) { data, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                guard let data else { return }
                if formatter.format == .json {
                    formatter.printJSON(data)
                } else {
                    let response = try! JSONDecoder().decode(WindowResponse.self, from: data)
                    formatter.printSingle([
                        ("ID:", "\(response.id)"),
                        ("Sessions:", "\(response.sessionCount)"),
                    ])
                }
            }
            semaphore.wait()
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a window")

        @Argument(help: "Window ID")
        var id: Int

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.closeWindow(id: id) { _, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                formatter.printSuccess("Window \(id) closed")
            }
            semaphore.wait()
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Focus a window")

        @Argument(help: "Window ID")
        var id: Int

        func run() throws {
            let client = XPCClient()
            let proxy = try client.proxy()
            let formatter = OutputFormatter(format: .detect(forceJSON: false, forceHuman: false))
            let semaphore = DispatchSemaphore(value: 0)

            proxy.focusWindow(id: id) { _, error in
                defer { semaphore.signal() }
                if let error {
                    formatter.printError(error.localizedDescription)
                    return
                }
                formatter.printSuccess("Focused window \(id)")
            }
            semaphore.wait()
        }
    }
}
```

**Step 2: Build**

Run: `swift build --target MisttyCLI`
Expected: Compiles.

**Step 3: Commit**

```bash
git add MisttyCLI/Commands/WindowCommand.swift
git commit -m "feat: implement CLI window commands (create, list, get, close, focus)"
```

---

### Task 13: Add launchd plist and install-service command

The XPC Mach service requires a launchd plist to register the service name.

**Files:**
- Create: `Resources/com.mistty.cli-service.plist`
- Modify: `Mistty/App/MisttyApp.swift` (auto-install on first launch)

**Step 1: Create launchd plist**

`Resources/com.mistty.cli-service.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mistty.cli-service</string>
    <key>MachServices</key>
    <dict>
        <key>com.mistty.cli-service</key>
        <true/>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Mistty.app/Contents/MacOS/Mistty</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
```

**Step 2: Auto-install plist on app launch**

In `Mistty/App/MisttyApp.swift`, add a helper that copies the plist to `~/Library/LaunchAgents/` on first run:

```swift
private func installXPCServiceIfNeeded() {
    let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    let plistPath = launchAgentsDir.appendingPathComponent("com.mistty.cli-service.plist")

    guard !FileManager.default.fileExists(atPath: plistPath.path) else { return }

    // Create LaunchAgents dir if needed
    try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

    // Write plist with current app path
    let appPath = Bundle.main.executablePath ?? "/Applications/Mistty.app/Contents/MacOS/Mistty"
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.mistty.cli-service</string>
        <key>MachServices</key>
        <dict>
            <key>com.mistty.cli-service</key>
            <true/>
        </dict>
        <key>ProgramArguments</key>
        <array>
            <string>\(appPath)</string>
        </array>
        <key>RunAtLoad</key>
        <false/>
    </dict>
    </plist>
    """
    try? plist.write(to: plistPath, atomically: true, encoding: .utf8)

    // Load the service
    let process = Process()
    process.executableURL = URL(filePath: "/bin/launchctl")
    process.arguments = ["load", plistPath.path]
    try? process.run()
    process.waitUntilExit()
}
```

Call this in the `MisttyApp.init()`:
```swift
init() {
    _ = GhosttyAppManager.shared
    installXPCServiceIfNeeded()
}
```

**Step 3: Build and verify**

Run: `swift build`
Expected: Compiles.

**Step 4: Commit**

```bash
git add Resources/com.mistty.cli-service.plist Mistty/App/MisttyApp.swift
git commit -m "feat: add launchd plist for XPC service with auto-install on first launch"
```

---

### Task 14: Add mistty-cli to justfile and bundle

**Files:**
- Modify: `justfile`

**Step 1: Add CLI build and install recipes**

Add to `justfile`:
```makefile
# Build the CLI tool
build-cli:
    swift build --target MisttyCLI

# Build CLI in release mode
build-cli-release:
    swift build --target MisttyCLI -c release

# Install CLI to /usr/local/bin
install-cli: build-cli-release
    cp .build/release/MisttyCLI /usr/local/bin/mistty-cli

# Uninstall CLI
uninstall-cli:
    rm -f /usr/local/bin/mistty-cli
```

Update the existing `bundle` recipe to also build and include the CLI:

In the bundle recipe, after copying the main binary, add:
```makefile
    swift build --target MisttyCLI {{BUILD_FLAGS}}
    cp .build/{{CONFIG}}/MisttyCLI $APP/Contents/MacOS/mistty-cli
```

**Step 2: Test build**

Run: `just build-cli`
Expected: CLI binary builds.

**Step 3: Commit**

```bash
git add justfile
git commit -m "feat: add CLI build and install recipes to justfile"
```

---

### Task 15: End-to-end manual testing

This task is manual — no automated tests since it requires a running app with XPC.

**Step 1: Build and install**

```bash
just bundle
just install-cli
```

**Step 2: Launch the app**

```bash
just run
```

**Step 3: Test CLI commands**

```bash
# Test session operations
mistty-cli session list
mistty-cli session create --name "test-project" --directory ~/Developer
mistty-cli session list
mistty-cli session get 1

# Test tab operations
mistty-cli tab list --session 1
mistty-cli tab create --session 1 --name "editor"
mistty-cli tab list --session 1
mistty-cli tab rename 2 --name "tests"

# Test pane operations
mistty-cli pane active
mistty-cli pane list --tab 1
mistty-cli pane create --tab 1 --direction horizontal
mistty-cli pane list --tab 1
mistty-cli pane send-keys "echo hello"
mistty-cli pane run-command "ls -la"
mistty-cli pane get-text

# Test JSON output
mistty-cli session list --json
mistty-cli session list | cat  # should auto-detect piped and output JSON

# Test error cases
mistty-cli session get 999
mistty-cli pane close 999

# Test window operations
mistty-cli window list
```

**Step 4: Fix any issues found**

Address any bugs or UX issues discovered during manual testing.

**Step 5: Commit fixes**

```bash
git add -A
git commit -m "fix: address issues found during CLI end-to-end testing"
```

---

### Task 16: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `PLAN.md`

**Step 1: Add CLI section to README**

Add a "CLI Control" section to README.md after the features section:

```markdown
## CLI Control

Mistty includes a CLI tool for controlling the terminal from scripts:

```bash
# Install the CLI
just install-cli

# Session management
mistty-cli session list
mistty-cli session create --name "project" --directory ~/code

# Tab management
mistty-cli tab create --session 1 --name "editor"
mistty-cli tab list --session 1

# Pane operations
mistty-cli pane active
mistty-cli pane split --tab 1 --direction horizontal
mistty-cli pane send-keys "echo hello"
mistty-cli pane run-command "npm test"

# JSON output (auto-detected when piped)
mistty-cli session list | jq .
mistty-cli session list --json
```
```

**Step 2: Mark CLI control as done in PLAN.md**

Update the v1 features section to indicate CLI control is implemented.

**Step 3: Commit**

```bash
git add README.md PLAN.md
git commit -m "docs: add CLI control documentation to README"
```
