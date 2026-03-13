# Post-MVP Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add daily-driver polish (bell indicators, tab rename, preferences), power-user pane management (window mode with resize/navigate/zoom/break/rotate), and vim-style copy mode for scrollback navigation.

**Architecture:** Three feature groups layered on top of existing `@Observable` models and notification-based event routing. Bell and window mode extend existing models; copy mode adds a new overlay and state machine. All features use the established pattern of `NSEvent.addLocalMonitorForEvents` for modal keyboard handling.

**Tech Stack:** Swift 6, SwiftUI, libghostty C API, TOMLKit, NSPasteboard

---

## Feature A: Polish & Daily-Driver Readiness

### Task 1: Bell Indicator — Model & Notification

**Files:**
- Modify: `Mistty/Models/MisttyTab.swift`
- Modify: `Mistty/App/GhosttyApp.swift`
- Test: `MisttyTests/Models/SessionStoreTests.swift`

**Step 1: Write the failing test**

Add to `SessionStoreTests.swift`:

```swift
func test_tabBellFlag() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertFalse(tab.hasBell)
    tab.hasBell = true
    XCTAssertTrue(tab.hasBell)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SessionStoreTests/test_tabBellFlag`
Expected: FAIL — `MisttyTab` has no `hasBell` property

**Step 3: Add `hasBell` to MisttyTab**

In `Mistty/Models/MisttyTab.swift`, add:

```swift
var hasBell = false
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SessionStoreTests/test_tabBellFlag`
Expected: PASS

**Step 5: Add RING_BELL action handler to GhosttyApp**

In `Mistty/App/GhosttyApp.swift`, add a new notification name:

```swift
static let ghosttyRingBell = Notification.Name("ghosttyRingBell")
```

In the `actionCallback` switch, add before the `default` case:

```swift
case GHOSTTY_ACTION_RING_BELL:
    if target.tag == GHOSTTY_TARGET_SURFACE {
        let surface = target.target.surface
        DispatchQueue.main.async {
            guard let userdata = ghostty_surface_userdata(surface) else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            NotificationCenter.default.post(
                name: .ghosttyRingBell,
                object: nil,
                userInfo: ["paneID": view.pane?.id as Any]
            )
        }
    }
    return true
```

**Step 6: Handle bell notification in ContentView**

In `Mistty/App/ContentView.swift`, add an `.onReceive` handler:

```swift
.onReceive(NotificationCenter.default.publisher(for: .ghosttyRingBell)) { notification in
    guard let paneID = notification.userInfo?["paneID"] as? UUID else { return }
    for session in store.sessions {
        for tab in session.tabs {
            // Only set bell if tab is not currently active
            if tab.panes.contains(where: { $0.id == paneID }),
               !(store.activeSession?.id == session.id && session.activeTab?.id == tab.id) {
                tab.hasBell = true
            }
        }
    }
}
```

Also clear the bell when switching tabs. In the existing tab switching logic, or add an `onChange`:

Where `session.activeTab` is set, clear the bell: `session.activeTab?.hasBell = false`

This is handled implicitly because switching tabs makes the tab active — but we need to clear on switch. Add to ContentView body, after the VStack with TabBarView:

```swift
.onChange(of: store.activeSession?.activeTab?.id) { _, _ in
    store.activeSession?.activeTab?.hasBell = false
}
```

**Step 7: Commit**

```bash
git add Mistty/Models/MisttyTab.swift Mistty/App/GhosttyApp.swift Mistty/App/ContentView.swift MisttyTests/Models/SessionStoreTests.swift
git commit -m "feat: bell indicator model and notification handling"
```

---

### Task 2: Bell Indicator — UI

**Files:**
- Modify: `Mistty/Views/TabBar/TabBarView.swift`
- Modify: `Mistty/Views/Sidebar/SidebarView.swift`

**Step 1: Add bell dot to TabBarItem**

In `TabBarView.swift`, in the `TabBarItem` body HStack, add before the `Text(tab.title)`:

```swift
if tab.hasBell {
    Circle()
        .fill(Color.orange)
        .frame(width: 6, height: 6)
}
```

**Step 2: Add bell dot to SidebarView tab rows**

In `SidebarView.swift`, in `SessionRowView`'s tab ForEach, add a bell indicator:

```swift
if tab.hasBell {
    Circle()
        .fill(Color.orange)
        .frame(width: 6, height: 6)
}
```

Add it inside the HStack before `Text(tab.title)`.

**Step 3: Build and verify visually**

Run: `just build`
Expected: Compiles without errors

**Step 4: Commit**

```bash
git add Mistty/Views/TabBar/TabBarView.swift Mistty/Views/Sidebar/SidebarView.swift
git commit -m "feat: bell indicator dots in tab bar and sidebar"
```

---

### Task 3: Tab Rename — Model & Inline Editing

**Files:**
- Modify: `Mistty/Models/MisttyTab.swift`
- Modify: `Mistty/Views/TabBar/TabBarView.swift`
- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/App/ContentView.swift`
- Test: `MisttyTests/Models/SessionStoreTests.swift`

**Step 1: Write the failing test**

Add to `SessionStoreTests.swift`:

```swift
func test_tabCustomTitle() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertEqual(tab.displayTitle, "Shell")
    tab.customTitle = "My Tab"
    XCTAssertEqual(tab.displayTitle, "My Tab")
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SessionStoreTests/test_tabCustomTitle`
Expected: FAIL — no `customTitle` or `displayTitle`

**Step 3: Add customTitle and displayTitle to MisttyTab**

In `Mistty/Models/MisttyTab.swift`:

```swift
var customTitle: String?

var displayTitle: String {
    customTitle ?? title
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SessionStoreTests/test_tabCustomTitle`
Expected: PASS

**Step 5: Add inline editing to TabBarItem**

In `TabBarView.swift`, add editing state and double-click:

Replace the `TabBarItem` struct with:

```swift
struct TabBarItem: View {
    @Bindable var tab: MisttyTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if tab.hasBell {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }

            if isEditing {
                TextField("Tab name", text: $editText, onCommit: {
                    tab.customTitle = editText.isEmpty ? nil : editText
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($editFocused)
                .frame(maxWidth: 120)
                .onAppear { editFocused = true }
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        editText = tab.displayTitle
                        isEditing = true
                    }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
        .onTapGesture { onSelect() }
    }
}
```

**Step 6: Update references from `tab.title` to `tab.displayTitle`**

In `SidebarView.swift`, change `Text(tab.title)` to `Text(tab.displayTitle)`.

**Step 7: Add rename shortcut**

In `MisttyApp.swift`, add:

```swift
Button("Rename Tab") {
    NotificationCenter.default.post(name: .misttyRenameTab, object: nil)
}
.keyboardShortcut("r", modifiers: [.command, .shift])
```

Add the notification name:

```swift
static let misttyRenameTab = Notification.Name("misttyRenameTab")
```

Handle in `ContentView.swift` — this is trickier since the TabBarItem owns the editing state. Instead, post a notification that TabBarView listens for. Add to `TabBarItem`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyRenameTab)) { _ in
    if isActive {
        editText = tab.displayTitle
        isEditing = true
    }
}
```

**Step 8: Build and verify**

Run: `just build`
Expected: Compiles

**Step 9: Commit**

```bash
git add Mistty/Models/MisttyTab.swift Mistty/Views/TabBar/TabBarView.swift Mistty/Views/Sidebar/SidebarView.swift Mistty/App/MisttyApp.swift MisttyTests/Models/SessionStoreTests.swift
git commit -m "feat: tab rename via double-click and Cmd+Shift+R"
```

---

### Task 4: Preference Pane

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift`
- Modify: `Mistty/App/MisttyApp.swift`
- Create: `Mistty/Views/Settings/SettingsView.swift`

**Step 1: Extend MisttyConfig with more settings**

In `Mistty/Config/MisttyConfig.swift`, add:

```swift
var cursorStyle: String = "block"
var scrollbackLines: Int = 10000
var sidebarVisible: Bool = true
```

Update `parse(_:)`:

```swift
if let cursor = table["cursor_style"]?.string { config.cursorStyle = cursor }
if let scrollback = table["scrollback_lines"]?.int { config.scrollbackLines = scrollback }
if let sidebar = table["sidebar_visible"]?.bool { config.sidebarVisible = sidebar }
```

Add a `save()` method:

```swift
func save() throws {
    let configURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mistty/config.toml")

    // Ensure directory exists
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    var lines: [String] = []
    lines.append("font_size = \(fontSize)")
    lines.append("font_family = \"\(fontFamily)\"")
    lines.append("cursor_style = \"\(cursorStyle)\"")
    lines.append("scrollback_lines = \(scrollbackLines)")
    lines.append("sidebar_visible = \(sidebarVisible)")
    try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
}
```

**Step 2: Create SettingsView**

Create `Mistty/Views/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @State private var config = MisttyConfig.load()

    var body: some View {
        Form {
            Section("Font") {
                TextField("Font Family", text: $config.fontFamily)
                Stepper("Font Size: \(config.fontSize)", value: $config.fontSize, in: 8...36)
            }

            Section("Terminal") {
                Picker("Cursor Style", selection: $config.cursorStyle) {
                    Text("Block").tag("block")
                    Text("Beam").tag("bar")
                    Text("Underline").tag("underline")
                }
                Stepper("Scrollback Lines: \(config.scrollbackLines)",
                        value: $config.scrollbackLines, in: 0...100000, step: 1000)
            }

            Section("Appearance") {
                Toggle("Show Sidebar by Default", isOn: $config.sidebarVisible)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
        .onChange(of: config.fontSize) { _, _ in saveConfig() }
        .onChange(of: config.fontFamily) { _, _ in saveConfig() }
        .onChange(of: config.cursorStyle) { _, _ in saveConfig() }
        .onChange(of: config.scrollbackLines) { _, _ in saveConfig() }
        .onChange(of: config.sidebarVisible) { _, _ in saveConfig() }
    }

    private func saveConfig() {
        try? config.save()
    }
}
```

**Step 3: Add Settings scene to MisttyApp**

In `MisttyApp.swift`, add after `WindowGroup`:

```swift
Settings {
    SettingsView()
}
```

**Step 4: Build and verify**

Run: `just build`
Expected: Compiles, Cmd+, opens preferences

**Step 5: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift Mistty/Views/Settings/SettingsView.swift Mistty/App/MisttyApp.swift
git commit -m "feat: preference pane with font, cursor, scrollback settings"
```

---

## Feature B: Power-User Pane Management (Window Mode)

### Task 5: Window Mode — State & Entry/Exit

**Files:**
- Modify: `Mistty/Models/MisttyTab.swift`
- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/App/ContentView.swift`
- Test: `MisttyTests/Models/SessionStoreTests.swift`

**Step 1: Write failing tests**

```swift
func test_windowModeToggle() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertFalse(tab.isWindowModeActive)
    tab.isWindowModeActive = true
    XCTAssertTrue(tab.isWindowModeActive)
}

func test_zoomedPaneToggle() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertNil(tab.zoomedPane)
    tab.zoomedPane = tab.panes[0]
    XCTAssertNotNil(tab.zoomedPane)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionStoreTests`
Expected: FAIL

**Step 3: Add window mode state to MisttyTab**

In `Mistty/Models/MisttyTab.swift`:

```swift
var isWindowModeActive = false
var zoomedPane: MisttyPane?
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionStoreTests`
Expected: PASS

**Step 5: Add Cmd+X shortcut**

In `MisttyApp.swift`, add:

```swift
Button("Window Mode") {
    NotificationCenter.default.post(name: .misttyWindowMode, object: nil)
}
.keyboardShortcut("x", modifiers: .command)
```

Add notification name:

```swift
static let misttyWindowMode = Notification.Name("misttyWindowMode")
```

**Step 6: Handle in ContentView — install/remove key monitor**

In `ContentView.swift`, add state:

```swift
@State private var windowModeMonitor: Any?
```

Add receiver:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyWindowMode)) { _ in
    guard let tab = store.activeSession?.activeTab else { return }
    tab.isWindowModeActive.toggle()
    if tab.isWindowModeActive {
        installWindowModeMonitor()
    } else {
        removeWindowModeMonitor()
    }
}
```

Add placeholder monitor methods:

```swift
private func installWindowModeMonitor() {
    windowModeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        // Will be filled in subsequent tasks
        switch event.keyCode {
        case 53: // Escape — exit window mode
            store.activeSession?.activeTab?.isWindowModeActive = false
            removeWindowModeMonitor()
            return nil
        default:
            return event
        }
    }
}

private func removeWindowModeMonitor() {
    if let monitor = windowModeMonitor {
        NSEvent.removeMonitor(monitor)
        windowModeMonitor = nil
    }
}
```

**Step 7: Commit**

```bash
git add Mistty/Models/MisttyTab.swift Mistty/App/MisttyApp.swift Mistty/App/ContentView.swift MisttyTests/Models/SessionStoreTests.swift
git commit -m "feat: window mode state and Cmd+X toggle"
```

---

### Task 6: Window Mode — Visual Indicator

**Files:**
- Modify: `Mistty/Views/Terminal/PaneView.swift`
- Modify: `Mistty/Views/Terminal/PaneLayoutView.swift`
- Modify: `Mistty/App/ContentView.swift`

**Step 1: Pass window mode state through views**

In `PaneLayoutView.swift`, add:

```swift
var isWindowModeActive: Bool = false
```

Pass it through recursive calls and to `PaneView`.

In `PaneView.swift`, add:

```swift
var isWindowModeActive: Bool = false
```

**Step 2: Show window mode border**

In `PaneView.swift`, modify the active border overlay:

```swift
.overlay {
    if isActive && isWindowModeActive {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.orange, lineWidth: 2)
            .allowsHitTesting(false)
    } else if isActive {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.accentColor, lineWidth: 1)
            .allowsHitTesting(false)
    }
}
```

**Step 3: Wire up in ContentView**

Pass `isWindowModeActive: tab.isWindowModeActive` to `PaneLayoutView`.

**Step 4: Build and verify**

Run: `just build`

**Step 5: Commit**

```bash
git add Mistty/Views/Terminal/PaneView.swift Mistty/Views/Terminal/PaneLayoutView.swift Mistty/App/ContentView.swift
git commit -m "feat: window mode orange border indicator"
```

---

### Task 7: Window Mode — Pane Navigation (Arrow Keys)

**Files:**
- Modify: `Mistty/Models/PaneLayout.swift`
- Modify: `Mistty/App/ContentView.swift`
- Test: `MisttyTests/Models/PaneLayoutTests.swift`

**Step 1: Write failing tests for adjacency**

In `PaneLayoutTests.swift`:

```swift
func test_adjacentPaneHorizontal() {
    let pane1 = MisttyPane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal)
    let panes = layout.leaves

    // Right of first pane should be second pane
    let right = layout.adjacentPane(from: panes[0], direction: .right)
    XCTAssertEqual(right?.id, panes[1].id)

    // Left of second pane should be first pane
    let left = layout.adjacentPane(from: panes[1], direction: .left)
    XCTAssertEqual(left?.id, panes[0].id)

    // Left of first pane should be nil (edge)
    let none = layout.adjacentPane(from: panes[0], direction: .left)
    XCTAssertNil(none)
}

func test_adjacentPaneVertical() {
    let pane1 = MisttyPane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .vertical)
    let panes = layout.leaves

    let down = layout.adjacentPane(from: panes[0], direction: .down)
    XCTAssertEqual(down?.id, panes[1].id)

    let up = layout.adjacentPane(from: panes[1], direction: .up)
    XCTAssertEqual(up?.id, panes[0].id)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter PaneLayoutTests`
Expected: FAIL

**Step 3: Add navigation direction enum and adjacentPane method**

In `Mistty/Models/PaneLayout.swift`, add:

```swift
enum NavigationDirection {
    case left, right, up, down
}
```

Add to `PaneLayout`:

```swift
func adjacentPane(from pane: MisttyPane, direction: NavigationDirection) -> MisttyPane? {
    // Find the path to this pane, then walk the tree
    guard let path = Self.findPath(root, target: pane.id) else { return nil }
    return Self.findAdjacent(root, path: path, direction: direction)
}

private static func findPath(_ node: PaneLayoutNode, target: UUID) -> [PathStep]? {
    switch node {
    case .leaf(let p):
        return p.id == target ? [] : nil
    case .split(_, let a, let b):
        if let path = findPath(a, target: target) {
            return [.left] + path
        }
        if let path = findPath(b, target: target) {
            return [.right] + path
        }
        return nil
    }
}

private enum PathStep { case left, right }

private static func findAdjacent(
    _ root: PaneLayoutNode,
    path: [PathStep],
    direction: NavigationDirection
) -> MisttyPane? {
    // Walk up the path to find the nearest split whose direction matches,
    // where the pane is on the "wrong" side (so we can cross to the other side)
    let splitDir: SplitDirection
    let fromSide: PathStep
    switch direction {
    case .left:  splitDir = .horizontal; fromSide = .right
    case .right: splitDir = .horizontal; fromSide = .left
    case .up:    splitDir = .vertical;   fromSide = .right
    case .down:  splitDir = .vertical;   fromSide = .left
    }

    // Walk up from the leaf looking for a split with matching direction
    // where we came from the correct side
    var node = root
    for (i, step) in path.enumerated() {
        guard case .split(let dir, let a, let b) = node else { break }
        if dir == splitDir && step == fromSide {
            // Found it — descend into the other subtree and find the nearest leaf
            let otherSubtree = (step == .left) ? b : a
            return (direction == .left || direction == .up)
                ? lastLeaf(otherSubtree)
                : firstLeaf(otherSubtree)
        }
        node = (step == .left) ? a : b
    }
    return nil
}

private static func firstLeaf(_ node: PaneLayoutNode) -> MisttyPane? {
    switch node {
    case .leaf(let p): return p
    case .split(_, let a, _): return firstLeaf(a)
    }
}

private static func lastLeaf(_ node: PaneLayoutNode) -> MisttyPane? {
    switch node {
    case .leaf(let p): return p
    case .split(_, _, let b): return lastLeaf(b)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter PaneLayoutTests`
Expected: PASS

**Step 5: Wire arrow keys in window mode monitor**

In `ContentView.swift`, update `installWindowModeMonitor`:

```swift
case 123: // Left arrow
    navigatePane(.left)
    return nil
case 124: // Right arrow
    navigatePane(.right)
    return nil
case 126: // Up arrow
    navigatePane(.up)
    return nil
case 125: // Down arrow
    navigatePane(.down)
    return nil
```

Add helper:

```swift
private func navigatePane(_ direction: NavigationDirection) {
    guard let tab = store.activeSession?.activeTab,
          let current = tab.activePane,
          let target = tab.layout.adjacentPane(from: current, direction: direction) else { return }
    tab.activePane = target
    target.surfaceView.window?.makeFirstResponder(target.surfaceView)
}
```

**Step 6: Commit**

```bash
git add Mistty/Models/PaneLayout.swift Mistty/App/ContentView.swift MisttyTests/Models/PaneLayoutTests.swift
git commit -m "feat: window mode pane navigation with arrow keys"
```

---

### Task 8: Window Mode — Split Ratio & Resize

**Files:**
- Modify: `Mistty/Models/PaneLayout.swift`
- Modify: `Mistty/Views/Terminal/PaneLayoutView.swift`
- Modify: `Mistty/App/ContentView.swift`
- Test: `MisttyTests/Models/PaneLayoutTests.swift`

**Step 1: Write failing test**

```swift
func test_splitRatio() {
    let pane1 = MisttyPane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal)
    // Default ratio should be 0.5
    if case .split(_, _, _, let ratio) = layout.root {
        XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    } else {
        XCTFail("Expected split node")
    }
}

func test_resizeSplit() {
    let pane1 = MisttyPane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal)
    let panes = layout.leaves
    layout.resizeSplit(containing: panes[0], delta: 0.1)
    if case .split(_, _, _, let ratio) = layout.root {
        XCTAssertEqual(ratio, 0.6, accuracy: 0.001)
    } else {
        XCTFail("Expected split node")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter PaneLayoutTests`
Expected: FAIL

**Step 3: Add ratio to PaneLayoutNode**

In `Mistty/Models/PaneLayout.swift`, change:

```swift
indirect enum PaneLayoutNode {
    case leaf(MisttyPane)
    case split(SplitDirection, PaneLayoutNode, PaneLayoutNode, CGFloat)
}
```

Update ALL existing code that creates or matches `.split` to include the ratio parameter (default `0.5`):

- `collectLeaves`: match `.split(_, let a, let b, _)`
- `removeNode`: match and reconstruct with ratio
- `insertSplit`: create with `0.5`
- `findPath`, `findAdjacent`: match with `_` for ratio

Add `resizeSplit` method:

```swift
mutating func resizeSplit(containing pane: MisttyPane, delta: CGFloat) {
    root = Self.adjustRatio(root, target: pane.id, delta: delta)
}

private static func adjustRatio(_ node: PaneLayoutNode, target: UUID, delta: CGFloat) -> PaneLayoutNode {
    switch node {
    case .leaf:
        return node
    case .split(let dir, let a, let b, let ratio):
        // Check if target is in subtree A
        let leavesA = collectLeaves(a)
        if leavesA.contains(where: { $0.id == target }) {
            // Check if it's a direct child
            if case .leaf(let p) = a, p.id == target {
                let newRatio = max(0.1, min(0.9, ratio + delta))
                return .split(dir, a, b, newRatio)
            }
            return .split(dir, adjustRatio(a, target: target, delta: delta), b, ratio)
        }
        let leavesB = collectLeaves(b)
        if leavesB.contains(where: { $0.id == target }) {
            if case .leaf(let p) = b, p.id == target {
                let newRatio = max(0.1, min(0.9, ratio + delta))
                return .split(dir, a, b, newRatio)
            }
            return .split(dir, a, adjustRatio(b, target: target, delta: delta), b: ratio)
        }
        return node
    }
}
```

**Step 4: Run test to verify passes**

Run: `swift test --filter PaneLayoutTests`
Expected: PASS

**Step 5: Update PaneLayoutView to use ratio**

In `PaneLayoutView.swift`, replace `HSplitView`/`VSplitView` with `GeometryReader` + ratio-based frames:

```swift
case .split(let direction, let a, let b, let ratio):
    let isHorizontal = direction == .horizontal
    GeometryReader { geo in
        if isHorizontal {
            HStack(spacing: 1) {
                PaneLayoutView(node: a, activePane: activePane, isWindowModeActive: isWindowModeActive,
                              onClosePane: onClosePane, onSelectPane: onSelectPane)
                    .frame(width: geo.size.width * ratio)
                Divider()
                PaneLayoutView(node: b, activePane: activePane, isWindowModeActive: isWindowModeActive,
                              onClosePane: onClosePane, onSelectPane: onSelectPane)
            }
        } else {
            VStack(spacing: 1) {
                PaneLayoutView(node: a, activePane: activePane, isWindowModeActive: isWindowModeActive,
                              onClosePane: onClosePane, onSelectPane: onSelectPane)
                    .frame(height: geo.size.height * ratio)
                Divider()
                PaneLayoutView(node: b, activePane: activePane, isWindowModeActive: isWindowModeActive,
                              onClosePane: onClosePane, onSelectPane: onSelectPane)
            }
        }
    }
```

**Step 6: Wire Cmd+Arrow for resize in window mode**

In `ContentView.swift`, in the window mode monitor, add:

```swift
// Cmd+Arrow to resize
if event.modifierFlags.contains(.command) {
    switch event.keyCode {
    case 123: // Cmd+Left
        resizeActivePane(delta: -0.05)
        return nil
    case 124: // Cmd+Right
        resizeActivePane(delta: 0.05)
        return nil
    case 126: // Cmd+Up
        resizeActivePane(delta: -0.05)
        return nil
    case 125: // Cmd+Down
        resizeActivePane(delta: 0.05)
        return nil
    default: break
    }
}
```

Add helper:

```swift
private func resizeActivePane(delta: CGFloat) {
    guard let tab = store.activeSession?.activeTab,
          let pane = tab.activePane else { return }
    tab.layout.resizeSplit(containing: pane, delta: delta)
}
```

**Step 7: Build and verify**

Run: `just build`

**Step 8: Commit**

```bash
git add Mistty/Models/PaneLayout.swift Mistty/Views/Terminal/PaneLayoutView.swift Mistty/App/ContentView.swift MisttyTests/Models/PaneLayoutTests.swift
git commit -m "feat: split ratio support and Cmd+Arrow resize in window mode"
```

---

### Task 9: Window Mode — Zoom (z key)

**Files:**
- Modify: `Mistty/App/ContentView.swift`
- Modify: `Mistty/Views/Terminal/PaneLayoutView.swift`

**Step 1: Wire `z` key in window mode monitor**

In `ContentView.swift`, add to window mode key handler:

```swift
case 6: // z
    toggleZoom()
    return nil
```

Add helper:

```swift
private func toggleZoom() {
    guard let tab = store.activeSession?.activeTab else { return }
    if tab.zoomedPane != nil {
        tab.zoomedPane = nil
    } else {
        tab.zoomedPane = tab.activePane
    }
}
```

**Step 2: Handle zoom in ContentView body**

In `ContentView.swift`, wrap the `PaneLayoutView` call — if zoomed, show just that pane:

```swift
if let zoomedPane = tab.zoomedPane {
    PaneView(
        pane: zoomedPane,
        isActive: true,
        isWindowModeActive: tab.isWindowModeActive,
        onClose: { closePane(zoomedPane) },
        onSelect: {}
    )
} else {
    PaneLayoutView(...)
}
```

**Step 3: Build and verify**

Run: `just build`

**Step 4: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat: window mode zoom toggle with z key"
```

---

### Task 10: Window Mode — Break Pane to Tab (b key)

**Files:**
- Modify: `Mistty/App/ContentView.swift`
- Modify: `Mistty/Models/MisttySession.swift`

**Step 1: Add `addTabWithPane` to MisttySession**

In `Mistty/Models/MisttySession.swift`:

```swift
func addTabWithPane(_ pane: MisttyPane) {
    let tab = MisttyTab(existingPane: pane)
    tabs.append(tab)
    activeTab = tab
}
```

This requires a new `MisttyTab` initializer. In `MisttyTab.swift`:

```swift
init(existingPane pane: MisttyPane) {
    self.directory = pane.directory
    layout = PaneLayout(pane: pane)
    panes = [pane]
    activePane = pane
}
```

**Step 2: Wire `b` key in window mode monitor**

```swift
case 11: // b — break pane to new tab
    breakPaneToTab()
    return nil
```

Add helper:

```swift
private func breakPaneToTab() {
    guard let session = store.activeSession,
          let tab = session.activeTab,
          let pane = tab.activePane,
          tab.panes.count > 1 else { return }
    tab.closePane(pane)
    if tab.panes.isEmpty { session.closeTab(tab) }
    session.addTabWithPane(pane)
}
```

**Step 3: Build and verify**

Run: `just build`

**Step 4: Commit**

```bash
git add Mistty/Models/MisttySession.swift Mistty/Models/MisttyTab.swift Mistty/App/ContentView.swift
git commit -m "feat: window mode break pane to tab with b key"
```

---

### Task 11: Window Mode — Rotate Split Direction (r key)

**Files:**
- Modify: `Mistty/Models/PaneLayout.swift`
- Modify: `Mistty/Models/SplitDirection.swift`
- Modify: `Mistty/App/ContentView.swift`
- Test: `MisttyTests/Models/PaneLayoutTests.swift`

**Step 1: Write failing test**

```swift
func test_rotateSplit() {
    let pane1 = MisttyPane()
    var layout = PaneLayout(pane: pane1)
    layout.split(pane: pane1, direction: .horizontal)
    layout.rotateDirection(containing: pane1)
    if case .split(let dir, _, _, _) = layout.root {
        XCTAssertEqual(dir, .vertical)
    } else {
        XCTFail("Expected split")
    }
}
```

**Step 2: Run test — expect fail**

Run: `swift test --filter PaneLayoutTests/test_rotateSplit`

**Step 3: Add `toggled` to SplitDirection**

In `SplitDirection.swift`:

```swift
var toggled: SplitDirection {
    switch self {
    case .horizontal: return .vertical
    case .vertical: return .horizontal
    }
}
```

Add `rotateDirection` to `PaneLayout`:

```swift
mutating func rotateDirection(containing pane: MisttyPane) {
    root = Self.rotate(root, target: pane.id)
}

private static func rotate(_ node: PaneLayoutNode, target: UUID) -> PaneLayoutNode {
    switch node {
    case .leaf:
        return node
    case .split(let dir, let a, let b, let ratio):
        let leaves = collectLeaves(node)
        if leaves.contains(where: { $0.id == target }) {
            // If target is a direct child, rotate this split
            let aLeaves = collectLeaves(a)
            let bLeaves = collectLeaves(b)
            if aLeaves.contains(where: { $0.id == target }) || bLeaves.contains(where: { $0.id == target }) {
                // Check if target is in a direct leaf
                let isDirectChild: Bool
                switch a {
                case .leaf(let p) where p.id == target: isDirectChild = true
                default:
                    switch b {
                    case .leaf(let p) where p.id == target: isDirectChild = true
                    default: isDirectChild = false
                    }
                }
                if isDirectChild {
                    return .split(dir.toggled, a, b, ratio)
                }
            }
            return .split(dir, rotate(a, target: target), rotate(b, target: target), ratio)
        }
        return node
    }
}
```

**Step 4: Run test — expect pass**

Run: `swift test --filter PaneLayoutTests/test_rotateSplit`

**Step 5: Wire `r` key**

```swift
case 15: // r — rotate split direction
    rotateActivePane()
    return nil
```

Add helper:

```swift
private func rotateActivePane() {
    guard let tab = store.activeSession?.activeTab,
          let pane = tab.activePane else { return }
    tab.layout.rotateDirection(containing: pane)
}
```

**Step 6: Commit**

```bash
git add Mistty/Models/PaneLayout.swift Mistty/Models/SplitDirection.swift Mistty/App/ContentView.swift MisttyTests/Models/PaneLayoutTests.swift
git commit -m "feat: window mode rotate split direction with r key"
```

---

## Feature D: Copy Mode

### Task 12: Copy Mode — State Machine

**Files:**
- Create: `Mistty/Models/CopyModeState.swift`
- Test: `MisttyTests/Models/CopyModeStateTests.swift`

**Step 1: Write failing tests**

Create `MisttyTests/Models/CopyModeStateTests.swift`:

```swift
import XCTest
@testable import Mistty

final class CopyModeStateTests: XCTestCase {
    func test_initialCursorPosition() {
        let state = CopyModeState(rows: 24, cols: 80)
        XCTAssertEqual(state.cursorRow, 23) // Bottom of screen
        XCTAssertEqual(state.cursorCol, 0)
    }

    func test_moveDown() {
        var state = CopyModeState(rows: 24, cols: 80)
        state.cursorRow = 10
        state.moveDown()
        XCTAssertEqual(state.cursorRow, 11)
    }

    func test_moveDownClampsToBottom() {
        var state = CopyModeState(rows: 24, cols: 80)
        state.cursorRow = 23
        state.moveDown()
        XCTAssertEqual(state.cursorRow, 23)
    }

    func test_moveRight() {
        var state = CopyModeState(rows: 24, cols: 80)
        state.moveRight()
        XCTAssertEqual(state.cursorCol, 1)
    }

    func test_toggleSelection() {
        var state = CopyModeState(rows: 24, cols: 80)
        XCTAssertFalse(state.isSelecting)
        state.toggleSelection()
        XCTAssertTrue(state.isSelecting)
        XCTAssertNotNil(state.selectionStart)
    }

    func test_homeAndEnd() {
        var state = CopyModeState(rows: 24, cols: 80)
        state.cursorCol = 40
        state.moveToLineStart()
        XCTAssertEqual(state.cursorCol, 0)
        state.moveToLineEnd()
        XCTAssertEqual(state.cursorCol, 79)
    }
}
```

**Step 2: Run test — expect fail**

Run: `swift test --filter CopyModeStateTests`

**Step 3: Create CopyModeState model**

Create `Mistty/Models/CopyModeState.swift`:

```swift
import Foundation

struct CopyModeState {
    let rows: Int
    let cols: Int
    var cursorRow: Int
    var cursorCol: Int = 0
    var isSelecting = false
    var selectionStart: (row: Int, col: Int)?
    var searchQuery: String = ""
    var isSearching = false

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.cursorRow = rows - 1
    }

    mutating func moveUp() { cursorRow = max(0, cursorRow - 1) }
    mutating func moveDown() { cursorRow = min(rows - 1, cursorRow + 1) }
    mutating func moveLeft() { cursorCol = max(0, cursorCol - 1) }
    mutating func moveRight() { cursorCol = min(cols - 1, cursorCol + 1) }
    mutating func moveToLineStart() { cursorCol = 0 }
    mutating func moveToLineEnd() { cursorCol = cols - 1 }
    mutating func moveToTop() { cursorRow = 0; cursorCol = 0 }
    mutating func moveToBottom() { cursorRow = rows - 1; cursorCol = 0 }

    mutating func toggleSelection() {
        isSelecting.toggle()
        if isSelecting {
            selectionStart = (cursorRow, cursorCol)
        } else {
            selectionStart = nil
        }
    }

    var selectionRange: (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
        guard isSelecting, let start = selectionStart else { return nil }
        return (start, (cursorRow, cursorCol))
    }
}
```

**Step 4: Run tests — expect pass**

Run: `swift test --filter CopyModeStateTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Mistty/Models/CopyModeState.swift MisttyTests/Models/CopyModeStateTests.swift
git commit -m "feat: copy mode state machine with cursor movement and selection"
```

---

### Task 13: Copy Mode — Entry/Exit & Key Monitor

**Files:**
- Modify: `Mistty/Models/MisttyTab.swift`
- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/App/ContentView.swift`

**Step 1: Add copy mode state to MisttyTab**

In `MisttyTab.swift`:

```swift
var copyModeState: CopyModeState?
var isCopyModeActive: Bool { copyModeState != nil }
```

**Step 2: Add keyboard shortcut**

In `MisttyApp.swift`:

```swift
Button("Copy Mode") {
    NotificationCenter.default.post(name: .misttyCopyMode, object: nil)
}
.keyboardShortcut("c", modifiers: [.command, .shift])
```

Add notification name:

```swift
static let misttyCopyMode = Notification.Name("misttyCopyMode")
```

**Step 3: Handle in ContentView**

Add state:

```swift
@State private var copyModeMonitor: Any?
```

Add receiver:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyCopyMode)) { _ in
    guard let tab = store.activeSession?.activeTab else { return }
    if tab.isCopyModeActive {
        exitCopyMode()
    } else {
        enterCopyMode()
    }
}
```

Add helpers:

```swift
private func enterCopyMode() {
    guard let tab = store.activeSession?.activeTab else { return }
    // TODO: get actual terminal dimensions from ghostty
    tab.copyModeState = CopyModeState(rows: 24, cols: 80)
    installCopyModeMonitor()
}

private func exitCopyMode() {
    store.activeSession?.activeTab?.copyModeState = nil
    removeCopyModeMonitor()
}

private func installCopyModeMonitor() {
    copyModeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard var state = store.activeSession?.activeTab?.copyModeState else { return event }

        switch event.keyCode {
        case 53: // Escape
            exitCopyMode()
            return nil
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers else { return event }
        switch chars {
        case "h": state.moveLeft()
        case "j": state.moveDown()
        case "k": state.moveUp()
        case "l": state.moveRight()
        case "0": state.moveToLineStart()
        case "$": state.moveToLineEnd()
        case "g":
            if event.modifierFlags.contains(.shift) {
                state.moveToBottom()
            } else {
                state.moveToTop()
            }
        case "v": state.toggleSelection()
        case "y":
            yankSelection()
            exitCopyMode()
            return nil
        default: break
        }

        store.activeSession?.activeTab?.copyModeState = state
        return nil
    }
}

private func removeCopyModeMonitor() {
    if let monitor = copyModeMonitor {
        NSEvent.removeMonitor(monitor)
        copyModeMonitor = nil
    }
}

private func yankSelection() {
    guard let tab = store.activeSession?.activeTab,
          let pane = tab.activePane,
          let state = tab.copyModeState,
          let range = state.selectionRange,
          let surface = pane.surfaceView.surface else { return }

    // Use ghostty_surface_read_text to get selected text
    var selection = ghostty_selection_s()
    selection.top_left = ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_EXACT,
        x: UInt32(range.start.col),
        y: UInt32(range.start.row)
    )
    selection.bottom_right = ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_EXACT,
        x: UInt32(range.end.col),
        y: UInt32(range.end.row)
    )
    selection.rectangle = false

    var text = ghostty_text_s()
    if ghostty_surface_read_text(surface, selection, &text) {
        if let data = text.text {
            let str = String(cString: data)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
        ghostty_surface_free_text(surface, &text)
    }
}
```

**Step 4: Build and verify**

Run: `just build`

**Step 5: Commit**

```bash
git add Mistty/Models/MisttyTab.swift Mistty/App/MisttyApp.swift Mistty/App/ContentView.swift
git commit -m "feat: copy mode entry/exit with Cmd+Shift+C and vim keybindings"
```

---

### Task 14: Copy Mode — Overlay View

**Files:**
- Create: `Mistty/Views/Terminal/CopyModeOverlay.swift`
- Modify: `Mistty/Views/Terminal/PaneView.swift`

**Step 1: Create CopyModeOverlay**

Create `Mistty/Views/Terminal/CopyModeOverlay.swift`:

```swift
import SwiftUI

struct CopyModeOverlay: View {
    let state: CopyModeState
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Selection highlight
            if let range = state.selectionRange {
                SelectionHighlightView(
                    start: range.start,
                    end: range.end,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight
                )
            }

            // Cursor
            Rectangle()
                .fill(Color.yellow.opacity(0.7))
                .frame(width: cellWidth, height: cellHeight)
                .offset(
                    x: CGFloat(state.cursorCol) * cellWidth,
                    y: CGFloat(state.cursorRow) * cellHeight
                )

            // Mode indicator
            VStack {
                Spacer()
                HStack {
                    Text(state.isSelecting ? "-- VISUAL --" : "-- COPY --")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    Spacer()
                }
                .padding(4)
            }
        }
        .allowsHitTesting(false)
    }
}

struct SelectionHighlightView: View {
    let start: (row: Int, col: Int)
    let end: (row: Int, col: Int)
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            let minRow = min(start.row, end.row)
            let maxRow = max(start.row, end.row)
            let startCol = start.row <= end.row ? start.col : end.col
            let endCol = start.row <= end.row ? end.col : start.col

            for row in minRow...maxRow {
                let x0: CGFloat
                let x1: CGFloat
                if row == minRow && row == maxRow {
                    x0 = CGFloat(min(startCol, endCol)) * cellWidth
                    x1 = CGFloat(max(startCol, endCol) + 1) * cellWidth
                } else if row == minRow {
                    x0 = CGFloat(startCol) * cellWidth
                    x1 = size.width
                } else if row == maxRow {
                    x0 = 0
                    x1 = CGFloat(endCol + 1) * cellWidth
                } else {
                    x0 = 0
                    x1 = size.width
                }
                let rect = CGRect(x: x0, y: CGFloat(row) * cellHeight, width: x1 - x0, height: cellHeight)
                context.fill(Path(rect), with: .color(.blue.opacity(0.3)))
            }
        }
    }
}
```

**Step 2: Wire overlay in PaneView**

In `PaneView.swift`, add:

```swift
var copyModeState: CopyModeState?
```

Add overlay after the existing ones:

```swift
.overlay {
    if let state = copyModeState {
        GeometryReader { geo in
            // Approximate cell dimensions — TODO: get from ghostty
            let cellW = geo.size.width / CGFloat(state.cols)
            let cellH = geo.size.height / CGFloat(state.rows)
            CopyModeOverlay(state: state, cellWidth: cellW, cellHeight: cellH)
        }
    }
}
```

**Step 3: Pass copy mode state through PaneLayoutView**

In `PaneLayoutView.swift`, add:

```swift
var copyModeState: CopyModeState?
var copyModePaneID: UUID?
```

Pass to PaneView only when the pane matches:

```swift
PaneView(
    pane: pane,
    isActive: activePane?.id == pane.id,
    isWindowModeActive: isWindowModeActive,
    copyModeState: (pane.id == copyModePaneID) ? copyModeState : nil,
    onClose: { onClosePane?(pane) },
    onSelect: { onSelectPane?(pane) }
)
```

**Step 4: Wire in ContentView**

Pass from tab state:

```swift
PaneLayoutView(
    node: tab.layout.root,
    activePane: tab.activePane,
    isWindowModeActive: tab.isWindowModeActive,
    copyModeState: tab.copyModeState,
    copyModePaneID: tab.activePane?.id,
    onClosePane: { pane in closePane(pane) },
    onSelectPane: { pane in tab.activePane = pane }
)
```

**Step 5: Build and verify**

Run: `just build`

**Step 6: Commit**

```bash
git add Mistty/Views/Terminal/CopyModeOverlay.swift Mistty/Views/Terminal/PaneView.swift Mistty/Views/Terminal/PaneLayoutView.swift Mistty/App/ContentView.swift
git commit -m "feat: copy mode overlay with cursor and selection highlighting"
```

---

### Task 15: Final — Integration Test & Cleanup

**Step 1: Run all tests**

Run: `swift test`
Expected: All tests pass

**Step 2: Format code**

Run: `just fmt`

**Step 3: Build release**

Run: `just build`

**Step 4: Fix any issues found**

Address compiler warnings or test failures.

**Step 5: Commit**

```bash
git add -A
git commit -m "chore: post-MVP phase 1 cleanup and formatting"
```
