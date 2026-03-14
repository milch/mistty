# Popup Windows Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add session-scoped popup terminal overlays that can be configured via config file, toggled via keyboard shortcuts, controlled via CLI, and managed in preferences.

**Architecture:** Popups are `MisttyPane` instances owned by `MisttySession`, rendered as centered ZStack overlays in `ContentView`. Each popup has a `PopupDefinition` (from config) and a `PopupState` (live instance). Shortcuts are registered dynamically from config. XPC protocol is extended with popup methods.

**Tech Stack:** Swift 6, SwiftUI, libghostty (GhosttyKit), TOMLKit, Swift Argument Parser, NSXPCConnection

---

### Task 1: PopupDefinition Model + Config Parsing

**Files:**
- Create: `Mistty/Models/PopupDefinition.swift`
- Modify: `Mistty/Config/MisttyConfig.swift`
- Modify: `MisttyTests/Config/MisttyConfigTests.swift`

**Step 1: Write failing tests for popup config parsing**

Add to `MisttyTests/Config/MisttyConfigTests.swift`:

```swift
func test_parsesPopupDefinitions() throws {
    let toml = """
        [[popup]]
        name = "lazygit"
        command = "lazygit"
        shortcut = "cmd+shift+g"
        width = 0.8
        height = 0.8
        close_on_exit = true

        [[popup]]
        name = "btop"
        command = "btop"
        width = 0.9
        height = 0.9
        close_on_exit = false
        """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.popups.count, 2)
    XCTAssertEqual(config.popups[0].name, "lazygit")
    XCTAssertEqual(config.popups[0].command, "lazygit")
    XCTAssertEqual(config.popups[0].shortcut, "cmd+shift+g")
    XCTAssertEqual(config.popups[0].width, 0.8)
    XCTAssertEqual(config.popups[0].height, 0.8)
    XCTAssertEqual(config.popups[0].closeOnExit, true)
    XCTAssertEqual(config.popups[1].name, "btop")
    XCTAssertEqual(config.popups[1].shortcut, nil)
    XCTAssertEqual(config.popups[1].closeOnExit, false)
}

func test_noPopupsReturnsEmptyArray() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertEqual(config.popups.count, 0)
}

func test_popupDefaultValues() throws {
    let toml = """
        [[popup]]
        name = "test"
        command = "test"
        """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.popups[0].width, 0.8)
    XCTAssertEqual(config.popups[0].height, 0.8)
    XCTAssertEqual(config.popups[0].closeOnExit, true)
    XCTAssertEqual(config.popups[0].shortcut, nil)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter MisttyConfigTests 2>&1 | tail -20`
Expected: FAIL — `popups` property doesn't exist on MisttyConfig

**Step 3: Create PopupDefinition model**

Create `Mistty/Models/PopupDefinition.swift`:

```swift
import Foundation

struct PopupDefinition: Sendable, Equatable {
    let name: String
    let command: String
    let shortcut: String?
    let width: Double
    let height: Double
    let closeOnExit: Bool

    init(name: String, command: String, shortcut: String? = nil, width: Double = 0.8, height: Double = 0.8, closeOnExit: Bool = true) {
        self.name = name
        self.command = command
        self.shortcut = shortcut
        self.width = width
        self.height = height
        self.closeOnExit = closeOnExit
    }
}
```

**Step 4: Add popup parsing to MisttyConfig**

In `Mistty/Config/MisttyConfig.swift`:

Add `var popups: [PopupDefinition] = []` property to the struct (after line 9).

In `parse(_:)`, after the existing key parsing (after line 20), add:

```swift
if let popupArray = table["popup"] as? [TOMLTable] {
    config.popups = popupArray.map { entry in
        PopupDefinition(
            name: entry["name"]?.string ?? "",
            command: entry["command"]?.string ?? "",
            shortcut: entry["shortcut"]?.string,
            width: entry["width"]?.double ?? 0.8,
            height: entry["height"]?.double ?? 0.8,
            closeOnExit: entry["close_on_exit"]?.bool ?? true
        )
    }
}
```

In `save()`, after the existing lines (after line 49), add popup serialization:

```swift
for popup in popups {
    lines.append("")
    lines.append("[[popup]]")
    lines.append("name = \"\(popup.name)\"")
    lines.append("command = \"\(popup.command)\"")
    if let shortcut = popup.shortcut {
        lines.append("shortcut = \"\(shortcut)\"")
    }
    lines.append("width = \(popup.width)")
    lines.append("height = \(popup.height)")
    lines.append("close_on_exit = \(popup.closeOnExit)")
}
```

**Step 5: Run tests to verify they pass**

Run: `swift test --filter MisttyConfigTests 2>&1 | tail -20`
Expected: PASS

**Step 6: Commit**

```bash
git add Mistty/Models/PopupDefinition.swift Mistty/Config/MisttyConfig.swift MisttyTests/Config/MisttyConfigTests.swift
git commit -m "feat: add PopupDefinition model and config parsing for [[popup]] entries"
```

---

### Task 2: PopupState Model + Session Integration

**Files:**
- Create: `Mistty/Models/PopupState.swift`
- Modify: `Mistty/Models/MisttySession.swift`
- Modify: `Mistty/Models/SessionStore.swift`

**Step 1: Create PopupState model**

Create `Mistty/Models/PopupState.swift`:

```swift
import Foundation

@Observable
@MainActor
final class PopupState: Identifiable {
    let id: Int
    let definition: PopupDefinition
    let pane: MisttyPane
    var isVisible: Bool

    init(id: Int, definition: PopupDefinition, pane: MisttyPane, isVisible: Bool = true) {
        self.id = id
        self.definition = definition
        self.pane = pane
        self.isVisible = isVisible
    }
}
```

**Step 2: Add popup ID generator to SessionStore**

In `Mistty/Models/SessionStore.swift`, add after `private var nextWindowId = 1` (line 18):

```swift
private var nextPopupId = 1
```

Add a generator method after `generateWindowID()` (after line 77):

```swift
private func generatePopupID() -> Int {
    let id = nextPopupId
    nextPopupId += 1
    return id
}
```

Pass a popup ID generator closure to sessions. In `createSession(...)` (line 40-64), add a `popupIDGenerator` parameter to the `MisttySession` init call:

```swift
popupIDGenerator: { [weak self] in
    guard let self else {
        assertionFailure("SessionStore was deallocated while sessions still exist")
        return 0
    }
    return self.generatePopupID()
}
```

**Step 3: Add popup support to MisttySession**

In `Mistty/Models/MisttySession.swift`, add properties after `var activeTab: MisttyTab?` (line 10):

```swift
private(set) var popups: [PopupState] = []
var activePopup: PopupState?

@ObservationIgnored
private(set) var popupIDGenerator: () -> Int
```

Update the `init` to accept and store `popupIDGenerator`:

```swift
init(id: Int, name: String, directory: URL, exec: String? = nil, tabIDGenerator: @escaping () -> Int, paneIDGenerator: @escaping () -> Int, popupIDGenerator: @escaping () -> Int) {
    self.id = id
    self.name = name
    self.directory = directory
    self.tabIDGenerator = tabIDGenerator
    self.paneIDGenerator = paneIDGenerator
    self.popupIDGenerator = popupIDGenerator
    addTab(exec: exec)
}
```

Add popup management methods:

```swift
func togglePopup(definition: PopupDefinition) {
    // If popup already exists for this definition, toggle visibility
    if let existing = popups.first(where: { $0.definition.name == definition.name }) {
        if existing.isVisible {
            existing.isVisible = false
            activePopup = nil
        } else {
            // Hide any other visible popup first
            activePopup?.isVisible = false
            existing.isVisible = true
            activePopup = existing
        }
        return
    }

    // Create new popup
    activePopup?.isVisible = false
    let pane = MisttyPane(id: paneIDGenerator())
    pane.directory = directory
    pane.command = definition.command
    let popup = PopupState(id: popupIDGenerator(), definition: definition, pane: pane)
    popups.append(popup)
    activePopup = popup
}

func closePopup(_ popup: PopupState) {
    popups.removeAll { $0.id == popup.id }
    if activePopup?.id == popup.id { activePopup = nil }
}

func hideActivePopup() {
    activePopup?.isVisible = false
    activePopup = nil
}
```

**Step 4: Add popup lookup to SessionStore**

In `Mistty/Models/SessionStore.swift`, add after `activePaneInfo()` (after line 127):

```swift
func popup(byId id: Int) -> (session: MisttySession, popup: PopupState)? {
    for session in sessions {
        if let popup = session.popups.first(where: { $0.id == id }) {
            return (session, popup)
        }
    }
    return nil
}
```

**Step 5: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Mistty/Models/PopupState.swift Mistty/Models/MisttySession.swift Mistty/Models/SessionStore.swift
git commit -m "feat: add PopupState model and session integration for popups"
```

---

### Task 3: Popup Overlay View

**Files:**
- Create: `Mistty/Views/Popup/PopupOverlayView.swift`

**Step 1: Create PopupOverlayView**

Create `Mistty/Views/Popup/PopupOverlayView.swift`:

```swift
import SwiftUI

struct PopupOverlayView: View {
    let popup: PopupState
    let onDismiss: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // Semi-transparent backdrop
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            // Popup container
            VStack(spacing: 0) {
                // Header bar
                HStack {
                    Text(popup.definition.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)

                // Terminal surface
                TerminalSurfaceRepresentable(pane: popup.pane)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 20, y: 5)
            .frame(
                width: popupWidth,
                height: popupHeight
            )
        }
    }

    private var popupWidth: CGFloat? {
        nil  // Will be constrained by GeometryReader in ContentView
    }

    private var popupHeight: CGFloat? {
        nil
    }
}
```

**Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Mistty/Views/Popup/PopupOverlayView.swift
git commit -m "feat: add PopupOverlayView with backdrop, header, and terminal surface"
```

---

### Task 4: ContentView Integration + Keyboard Handling

**Files:**
- Modify: `Mistty/App/ContentView.swift`
- Modify: `Mistty/App/MisttyApp.swift`

**Step 1: Add popup overlay to ContentView**

In `Mistty/App/ContentView.swift`, add a `@State` property after the existing state vars (after line 14):

```swift
@State private var popupMonitor: Any?
```

After the existing `.overlay` block for session manager (after line 101), add another overlay for popups:

```swift
.overlay {
    if let session = store.activeSession,
       let popup = session.activePopup,
       popup.isVisible
    {
        GeometryReader { geometry in
            PopupOverlayView(
                popup: popup,
                onDismiss: {
                    session.hideActivePopup()
                    returnFocusToActivePane()
                },
                onClose: {
                    session.closePopup(popup)
                    returnFocusToActivePane()
                }
            )
            .frame(
                width: geometry.size.width * popup.definition.width,
                height: geometry.size.height * popup.definition.height
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

**Step 2: Add popup toggle notification handler**

In `Mistty/App/MisttyApp.swift`, add a new notification name after the existing ones (after line 150):

```swift
static let misttyPopupToggle = Notification.Name("misttyPopupToggle")
```

In `Mistty/App/ContentView.swift`, add an `.onReceive` handler after the existing ones (before the closing `}` of the body, around line 196):

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyPopupToggle)) { notification in
    guard let session = store.activeSession,
          let name = notification.userInfo?["name"] as? String
    else { return }
    let config = MisttyConfig.load()
    guard let definition = config.popups.first(where: { $0.name == name }) else { return }
    session.togglePopup(definition: definition)
    // Focus the popup surface if it became visible
    if let popup = session.activePopup, popup.isVisible {
        DispatchQueue.main.async {
            popup.pane.surfaceView.window?.makeFirstResponder(popup.pane.surfaceView)
        }
    }
}
```

**Step 3: Handle ghosttyCloseSurface for popups**

In ContentView's existing `.onReceive(NotificationCenter.default.publisher(for: .ghosttyCloseSurface))` handler (lines 185-196), add popup handling before the existing pane loop:

```swift
// Check if this is a popup pane
for session in store.sessions {
    if let popup = session.popups.first(where: { $0.pane.id == paneID }) {
        if popup.definition.closeOnExit {
            session.closePopup(popup)
        } else {
            popup.isVisible = false
            if session.activePopup?.id == popup.id {
                session.activePopup = nil
            }
        }
        returnFocusToActivePane()
        return
    }
}
```

**Step 4: Add Cmd+W handling for popups**

In the existing `.onReceive(NotificationCenter.default.publisher(for: .misttyClosePane))` handler (lines 124-129), add popup check at the top:

```swift
// Close active popup if one is showing
if let session = store.activeSession,
   let popup = session.activePopup,
   popup.isVisible
{
    session.closePopup(popup)
    returnFocusToActivePane()
    return
}
```

**Step 5: Add returnFocusToActivePane helper**

Add a private method to ContentView:

```swift
private func returnFocusToActivePane() {
    if let pane = store.activeSession?.activeTab?.activePane {
        DispatchQueue.main.async {
            pane.surfaceView.window?.makeFirstResponder(pane.surfaceView)
        }
    }
}
```

**Step 6: Register popup shortcuts in MisttyApp**

In `Mistty/App/MisttyApp.swift`, in the `.commands` block (after the "Rename Tab" button, around line 131), add dynamic popup shortcut buttons:

```swift
Divider()

ForEach(Array(MisttyConfig.load().popups.enumerated()), id: \.offset) { _, popup in
    if let shortcut = popup.shortcut, let key = parseShortcutKey(shortcut), let modifiers = parseShortcutModifiers(shortcut) {
        Button("Toggle \(popup.name)") {
            NotificationCenter.default.post(
                name: .misttyPopupToggle,
                object: nil,
                userInfo: ["name": popup.name]
            )
        }
        .keyboardShortcut(key, modifiers: modifiers)
    }
}
```

Add shortcut parsing helpers as private functions on MisttyApp:

```swift
private func parseShortcutKey(_ shortcut: String) -> KeyEquivalent? {
    let parts = shortcut.lowercased().split(separator: "+")
    guard let last = parts.last, last.count == 1, let char = last.first else { return nil }
    return KeyEquivalent(char)
}

private func parseShortcutModifiers(_ shortcut: String) -> EventModifiers? {
    let parts = shortcut.lowercased().split(separator: "+")
    var modifiers: EventModifiers = []
    for part in parts.dropLast() {
        switch part {
        case "cmd", "command": modifiers.insert(.command)
        case "shift": modifiers.insert(.shift)
        case "opt", "option", "alt": modifiers.insert(.option)
        case "ctrl", "control": modifiers.insert(.control)
        default: break
        }
    }
    return modifiers.isEmpty ? nil : modifiers
}
```

**Step 7: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 8: Commit**

```bash
git add Mistty/App/ContentView.swift Mistty/App/MisttyApp.swift
git commit -m "feat: integrate popup overlay in ContentView with keyboard shortcuts and lifecycle"
```

---

### Task 5: XPC Protocol + Response + Service Implementation

**Files:**
- Modify: `MisttyShared/MisttyServiceProtocol.swift`
- Create: `MisttyShared/Models/PopupResponse.swift`
- Modify: `Mistty/Services/XPCService.swift`

**Step 1: Add PopupResponse model**

Create `MisttyShared/Models/PopupResponse.swift`:

```swift
import Foundation

public struct PopupResponse: Codable, Sendable {
    public let id: Int
    public let name: String
    public let command: String
    public let isVisible: Bool
    public let paneId: Int

    public init(id: Int, name: String, command: String, isVisible: Bool, paneId: Int) {
        self.id = id
        self.name = name
        self.command = command
        self.isVisible = isVisible
        self.paneId = paneId
    }
}
```

**Step 2: Add popup methods to XPC protocol**

In `MisttyShared/MisttyServiceProtocol.swift`, add after the Windows section (before the closing `}`):

```swift
// MARK: - Popups

func openPopup(sessionId: Int, name: String, exec: String, width: Double, height: Double, closeOnExit: Bool, reply: @escaping (Data?, Error?) -> Void)
func closePopup(popupId: Int, reply: @escaping (Data?, Error?) -> Void)
func togglePopup(sessionId: Int, name: String, reply: @escaping (Data?, Error?) -> Void)
func listPopups(sessionId: Int, reply: @escaping (Data?, Error?) -> Void)
```

**Step 3: Implement popup methods in XPCService**

In `Mistty/Services/XPCService.swift`, add a `popupResponse` helper after `paneResponse` (after line 58):

```swift
@MainActor private func popupResponse(_ popup: PopupState) -> PopupResponse {
    PopupResponse(
        id: popup.id,
        name: popup.definition.name,
        command: popup.definition.command,
        isVisible: popup.isVisible,
        paneId: popup.pane.id
    )
}
```

Add the popup method implementations after the Windows section (before the closing `}`):

```swift
// MARK: - Popups

func openPopup(sessionId: Int, name: String, exec: String, width: Double, height: Double, closeOnExit: Bool, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
        guard let session = self.store.session(byId: sessionId) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Session \(sessionId) not found"))
            return
        }
        let definition = PopupDefinition(name: name, command: exec, width: width, height: height, closeOnExit: closeOnExit)
        session.togglePopup(definition: definition)
        guard let popup = session.activePopup else {
            reply(nil, MisttyXPC.error(.operationFailed, "Failed to create popup"))
            return
        }
        reply(self.encode(self.popupResponse(popup)), nil)
    }
}

func closePopup(popupId: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
        guard let (session, popup) = self.store.popup(byId: popupId) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Popup \(popupId) not found"))
            return
        }
        session.closePopup(popup)
        reply(self.encode([String: String]()), nil)
    }
}

func togglePopup(sessionId: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
        guard let session = self.store.session(byId: sessionId) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Session \(sessionId) not found"))
            return
        }
        let config = MisttyConfig.load()
        guard let definition = config.popups.first(where: { $0.name == name }) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Popup definition '\(name)' not found in config"))
            return
        }
        session.togglePopup(definition: definition)
        if let popup = session.popups.first(where: { $0.definition.name == name }) {
            reply(self.encode(self.popupResponse(popup)), nil)
        } else {
            reply(self.encode([String: String]()), nil)
        }
    }
}

func listPopups(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
        guard let session = self.store.session(byId: sessionId) else {
            reply(nil, MisttyXPC.error(.entityNotFound, "Session \(sessionId) not found"))
            return
        }
        let responses = session.popups.map { self.popupResponse($0) }
        reply(self.encode(responses), nil)
    }
}
```

**Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add MisttyShared/MisttyServiceProtocol.swift MisttyShared/Models/PopupResponse.swift Mistty/Services/XPCService.swift
git commit -m "feat: add popup XPC protocol methods, PopupResponse, and service implementation"
```

---

### Task 6: CLI Popup Command

**Files:**
- Create: `MisttyCLI/Commands/PopupCommand.swift`
- Modify: `MisttyCLI/MisttyCLI.swift`

**Step 1: Create PopupCommand**

Create `MisttyCLI/Commands/PopupCommand.swift`:

```swift
import ArgumentParser
import Foundation
import MisttyShared

struct PopupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "popup",
        abstract: "Manage popup windows",
        subcommands: [
            Open.self,
            Close.self,
            Toggle.self,
            List.self,
        ]
    )

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a popup window")

        @Option(name: .long, help: "Session ID (defaults to active session)")
        var session: Int?

        @Option(name: .long, help: "Popup name (from config)")
        var name: String?

        @Option(name: .long, help: "Command to execute")
        var exec: String?

        @Option(name: .long, help: "Width as fraction of window (0.0-1.0)")
        var width: Double = 0.8

        @Option(name: .long, help: "Height as fraction of window (0.0-1.0)")
        var height: Double = 0.8

        @Flag(name: .long, help: "Close popup when process exits")
        var closeOnExit: Bool = false

        @Flag(name: .long, help: "Keep popup open when process exits")
        var keepOnExit: Bool = false

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = XPCClient()
            let proxy = try client.connect()

            // Determine session ID — use provided or resolve active
            let sessionId: Int
            if let sid = session {
                sessionId = sid
            } else {
                // Get active session by listing and taking the first
                let semaphore = DispatchSemaphore(value: 0)
                var resultData: Data?
                proxy.listSessions { data, _ in
                    resultData = data
                    semaphore.signal()
                }
                semaphore.wait()
                guard let data = resultData,
                      let sessions = try? JSONDecoder().decode([SessionResponse].self, from: data),
                      let first = sessions.first
                else {
                    OutputFormatter.printError("No active session. Specify --session")
                    Foundation.exit(1)
                }
                sessionId = first.id
            }

            // Determine popup name and exec
            let popupName = name ?? exec ?? "popup"
            guard let command = exec ?? name else {
                OutputFormatter.printError("Provide --name (from config) or --exec (ad-hoc command)")
                Foundation.exit(1)
            }

            let shouldCloseOnExit = closeOnExit || !keepOnExit

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.openPopup(sessionId: sessionId, name: popupName, exec: command, width: width, height: height, closeOnExit: shouldCloseOnExit) { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            guard let data = resultData else {
                OutputFormatter.printError("No response from Mistty")
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let popup = try? JSONDecoder().decode(PopupResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(popup.id)"),
                        ("Name", popup.name),
                        ("Command", popup.command),
                        ("Visible", "\(popup.isVisible)"),
                        ("Pane ID", "\(popup.paneId)"),
                    ])
                }
            }
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a popup window")

        @Argument(help: "Popup ID")
        var id: Int

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultError: Error?

            proxy.closePopup(popupId: id) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Popup \(id) closed")
        }
    }

    struct Toggle: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Toggle a named popup")

        @Argument(help: "Popup name (from config)")
        var name: String

        @Option(name: .long, help: "Session ID (defaults to active session)")
        var session: Int?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = XPCClient()
            let proxy = try client.connect()

            let sessionId: Int
            if let sid = session {
                sessionId = sid
            } else {
                let semaphore = DispatchSemaphore(value: 0)
                var resultData: Data?
                proxy.listSessions { data, _ in
                    resultData = data
                    semaphore.signal()
                }
                semaphore.wait()
                guard let data = resultData,
                      let sessions = try? JSONDecoder().decode([SessionResponse].self, from: data),
                      let first = sessions.first
                else {
                    OutputFormatter.printError("No active session. Specify --session")
                    Foundation.exit(1)
                }
                sessionId = first.id
            }

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.togglePopup(sessionId: sessionId, name: name) { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            guard let data = resultData else {
                OutputFormatter.printError("No response from Mistty")
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let popup = try? JSONDecoder().decode(PopupResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(popup.id)"),
                        ("Name", popup.name),
                        ("Visible", "\(popup.isVisible)"),
                    ])
                } else {
                    formatter.printSuccess("Popup '\(name)' toggled")
                }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List popup windows")

        @Option(name: .long, help: "Session ID (defaults to active session)")
        var session: Int?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = XPCClient()
            let proxy = try client.connect()

            let sessionId: Int
            if let sid = session {
                sessionId = sid
            } else {
                let semaphore = DispatchSemaphore(value: 0)
                var resultData: Data?
                proxy.listSessions { data, _ in
                    resultData = data
                    semaphore.signal()
                }
                semaphore.wait()
                guard let data = resultData,
                      let sessions = try? JSONDecoder().decode([SessionResponse].self, from: data),
                      let first = sessions.first
                else {
                    OutputFormatter.printError("No active session. Specify --session")
                    Foundation.exit(1)
                }
                sessionId = first.id
            }

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.listPopups(sessionId: sessionId) { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            guard let data = resultData else {
                OutputFormatter.printError("No response from Mistty")
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let popups = try? JSONDecoder().decode([PopupResponse].self, from: data) {
                    let rows = popups.map { p in
                        ["\(p.id)", p.name, p.command, p.isVisible ? "visible" : "hidden", "\(p.paneId)"]
                    }
                    formatter.printTable(
                        headers: ["ID", "NAME", "COMMAND", "STATUS", "PANE"],
                        rows: rows
                    )
                }
            }
        }
    }
}
```

**Step 2: Register PopupCommand in MisttyCLI**

In `MisttyCLI/MisttyCLI.swift`, add `PopupCommand.self` to the subcommands array:

```swift
subcommands: [
    SessionCommand.self,
    TabCommand.self,
    PaneCommand.self,
    WindowCommand.self,
    PopupCommand.self,
]
```

**Step 3: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add MisttyCLI/Commands/PopupCommand.swift MisttyCLI/MisttyCLI.swift
git commit -m "feat: add mistty-cli popup command with open/close/toggle/list subcommands"
```

---

### Task 7: Preferences Pane — Popup Management

**Files:**
- Modify: `Mistty/Views/Settings/SettingsView.swift`
- Modify: `Mistty/Config/MisttyConfig.swift`

**Step 1: Make MisttyConfig observable for Settings**

The config is currently a plain struct. The `SettingsView` already uses `@State private var config = MisttyConfig.load()` and mutates it. No changes needed to the config struct — the existing pattern works since `popups` is an array value type.

**Step 2: Add Popups section to SettingsView**

In `Mistty/Views/Settings/SettingsView.swift`, add a new Section after the "Appearance" section (after line 26):

```swift
Section("Popups") {
    ForEach(config.popups.indices, id: \.self) { index in
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Name", text: $config.popups[index].name)
                    .frame(width: 120)
                TextField("Command", text: $config.popups[index].command)
                    .frame(width: 150)
                TextField("Shortcut", text: Binding(
                    get: { config.popups[index].shortcut ?? "" },
                    set: { config.popups[index].shortcut = $0.isEmpty ? nil : $0 }
                ))
                .frame(width: 120)
                Button(role: .destructive) {
                    config.popups.remove(at: index)
                    saveConfig()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("Size:")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: $config.popups[index].width, in: 0.3...1.0, step: 0.05) {
                    Text("W: \(Int(config.popups[index].width * 100))%")
                        .font(.caption)
                        .frame(width: 45)
                }
                Slider(value: $config.popups[index].height, in: 0.3...1.0, step: 0.05) {
                    Text("H: \(Int(config.popups[index].height * 100))%")
                        .font(.caption)
                        .frame(width: 45)
                }
                Toggle("Close on exit", isOn: $config.popups[index].closeOnExit)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    Button("Add Popup") {
        config.popups.append(PopupDefinition(name: "", command: ""))
        saveConfig()
    }
}
```

**Step 3: Make PopupDefinition properties mutable**

In `Mistty/Models/PopupDefinition.swift`, change all `let` to `var` so the settings pane can edit them:

```swift
struct PopupDefinition: Sendable, Equatable {
    var name: String
    var command: String
    var shortcut: String?
    var width: Double
    var height: Double
    var closeOnExit: Bool
    // ... init stays the same
}
```

**Step 4: Add onChange handlers for popup config fields**

In `Mistty/Views/Settings/SettingsView.swift`, add after the existing `.onChange` handlers (after line 35):

```swift
.onChange(of: config.popups) { _, _ in saveConfig() }
```

This requires `PopupDefinition` to conform to `Equatable` (already declared in Step 3's struct).

**Step 5: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Mistty/Views/Settings/SettingsView.swift Mistty/Models/PopupDefinition.swift
git commit -m "feat: add Popups section to preferences pane with add/edit/remove support"
```
