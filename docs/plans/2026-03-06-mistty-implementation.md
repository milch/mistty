# Mistty Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS terminal emulator with native session management (tabs, split panes, fuzzy session switcher) on top of libghostty.

**Architecture:** Two-phase — Phase 0 spikes libghostty to discover API constraints, Phase 1 builds the MVP using protocol-based session/tab/pane abstractions designed for future daemon migration.

**Tech Stack:** Swift 6, SwiftUI, libghostty (C API), XCTest, TOMLKit

---

## Phase 0: Spike

> Goal: Understand libghostty's surface lifecycle, event model, and rendering requirements before committing to Phase 1 architecture.

### Task 1: Create Swift Package Manager project

**Files:**
- Create: `Package.swift`
- Create: `Mistty/MisttyApp.swift`
- Create: `Mistty/ContentView.swift`
- Create: `MisttyTests/MisttyTests.swift`

**Step 1: Initialize with SPM**

```bash
cd /Users/manu/Developer/mistty
swift package init --name Mistty --type executable
```

**Step 2: Update Package.swift for macOS 14 SwiftUI app**

Edit `Package.swift` to set the platform to `.macOS(.v14)` and add SwiftUI as a framework dependency.

**Step 3: Create source files**

Create `Mistty/MisttyApp.swift` with `@main` App entry point and `Mistty/ContentView.swift` with initial SwiftUI view. Create `MisttyTests/MisttyTests.swift` with a placeholder XCTest case.

**Step 4: Initialize git**

```bash
cd /Users/manu/Developer/mistty
git init
cat > .gitignore << 'EOF'
.DS_Store
*.xcuserstate
xcuserdata/
.build/
DerivedData/
.claude/
EOF
git add .
git commit -m "chore: initial SPM project"
```

Expected: Repository initialized with initial commit.

---

### Task 2: Research libghostty availability

**Step 1: Check if Ghostty.app is installed**

```bash
ls /Applications/Ghostty.app/Contents/ 2>/dev/null || echo "Ghostty not installed"
find /Applications/Ghostty.app -name "*.dylib" -o -name "libghostty*" 2>/dev/null | head -20
```

**Step 2: Check Ghostty source on GitHub**

Browse https://github.com/ghostty-org/ghostty — look at:
- `macos/Sources/` — Swift layer structure
- `include/ghostty.h` — the C API surface
- How `ghostty_surface_t` is created, sized, and destroyed
- How input events are forwarded
- How rendering is triggered (callback vs poll)
- Whether Metal or another renderer is used

**Step 3: Document findings**

Create `docs/spike/libghostty-api.md` and write:
- How to obtain the library (build from source vs extract from app bundle)
- The surface lifecycle: create → resize → input → render → destroy
- Threading model (is rendering on main thread? background?)
- How output/bell events are surfaced to the host app
- Any Objective-C or Swift bridging requirements

**Step 4: Commit**

```bash
git add docs/spike/
git commit -m "docs: libghostty API research notes"
```

---

### Task 3: Link libghostty in Xcode

**Step 1: Obtain libghostty**

Based on Task 2 findings, either:

Option A — Extract from Ghostty.app bundle:
```bash
cp /Applications/Ghostty.app/Contents/Frameworks/libghostty.dylib ./vendor/
cp /path/to/ghostty.h ./vendor/
```

Option B — Build from Ghostty source:
```bash
git clone https://github.com/ghostty-org/ghostty /tmp/ghostty
cd /tmp/ghostty
zig build -Doptimize=ReleaseFast 2>&1 | tail -20
```

**Step 2: Add to Xcode project**

In Xcode:
1. Drag the `.dylib` or `.a` into the project navigator → add to Mistty target
2. In Build Settings → Header Search Paths, add the path to `ghostty.h`
3. Create a bridging header at `Mistty/Mistty-Bridging-Header.h`:

```c
#include "ghostty.h"
```

4. In Build Settings → Swift Compiler - General → Objective-C Bridging Header, set the path.

**Step 3: Verify it links**

```bash
swift build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`

**Step 4: Commit**

```bash
git add vendor/ Mistty/Mistty-Bridging-Header.h
git commit -m "chore: link libghostty"
```

---

### Task 4: Render a terminal surface

> This is exploratory. The exact API calls depend on Task 2 findings. Fill in based on actual `ghostty.h`.

**Step 1: Create a minimal NSView subclass**

Create `Mistty/Spike/GhosttyTerminalView.swift`:

```swift
import AppKit

// SPIKE ONLY — will be thrown away after spike conclusions are written
final class GhosttyTerminalView: NSView {
    // ghostty_surface_t handle — exact type from ghostty.h
    // var surface: ghostty_surface_t?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // TODO: create ghostty app + surface using API from ghostty.h
        // Refer to docs/spike/libghostty-api.md for exact calls
    }

    required init?(coder: NSCoder) { fatalError() }

    override func keyDown(with event: NSEvent) {
        // TODO: forward to ghostty surface
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // TODO: notify ghostty surface of resize
    }
}
```

**Step 2: Wrap in NSViewRepresentable**

Create `Mistty/Spike/GhosttyTerminalViewRepresentable.swift`:

```swift
import SwiftUI

struct GhosttyTerminalViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> GhosttyTerminalView {
        GhosttyTerminalView(frame: .zero)
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {}
}
```

**Step 3: Wire into ContentView**

```swift
struct ContentView: View {
    var body: some View {
        GhosttyTerminalViewRepresentable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Step 4: Build and run**

```bash
swift build 2>&1 | tail -10
```

Open the app. Verify:
- A window appears with a terminal prompt
- Typing characters appears in the terminal
- Running `ls` shows output
- Resizing the window causes the terminal to reflow

**Step 5: Commit**

```bash
git add Mistty/Spike/
git commit -m "spike: working libghostty surface in SwiftUI"
```

---

### Task 5: Write spike conclusions

Create `docs/spike/conclusions.md`:

Document:
- Exact function signatures needed for a working surface
- How multiple independent surfaces (one per pane) are managed
- Whether libghostty handles layout or the app does
- Threading constraints (what must run on main thread)
- Any constraints that change the Phase 1 design
- Recommended adjustments to the MVP architecture from the design doc

```bash
git add docs/spike/conclusions.md
git commit -m "docs: spike conclusions"
```

---

> ⚠️ **STOP — review `docs/spike/conclusions.md` before continuing.**
> Adjust Phase 1 tasks below as needed based on findings.

---

## Phase 1: MVP

### Task 6: Project structure and dependencies

**Files:**
- Create: `Mistty/App/MisttyApp.swift`
- Create: `Mistty/App/ContentView.swift`
- Create: `Mistty/Config/` (directory)
- Create: `Mistty/Models/` (directory)
- Create: `Mistty/Views/Sidebar/` (directory)
- Create: `Mistty/Views/SessionManager/` (directory)
- Create: `Mistty/Views/Terminal/` (directory)
- Create: `Mistty/Views/TabBar/` (directory)
- Create: `Mistty/Services/` (directory)
- Create: `MisttyTests/Config/` (directory)
- Create: `MisttyTests/Models/` (directory)
- Create: `MisttyTests/Services/` (directory)

**Step 1: Add TOMLKit via SPM**

In Xcode → File → Add Package Dependencies:
- URL: `https://github.com/LebJe/TOMLKit`
- Add to: Mistty target

**Step 2: Add a fuzzy matching package**

Evaluate and add one of:
- `https://github.com/nicklockwood/FuzzySearch`
- Or implement simple `localizedCaseInsensitiveContains` for MVP (good enough)

**Step 3: Move spike files**

```bash
mkdir -p Mistty/Spike
# Spike files are already in Mistty/Spike/ — leave them there for reference
```

**Step 4: Commit**

```bash
git add .
git commit -m "chore: project structure and SPM dependencies"
```

---

### Task 7: Config parser

**Files:**
- Create: `Mistty/Config/MisttyConfig.swift`
- Create: `MisttyTests/Config/MisttyConfigTests.swift`

**Step 1: Write failing tests**

`MisttyTests/Config/MisttyConfigTests.swift`:

```swift
import XCTest
@testable import Mistty

final class MisttyConfigTests: XCTestCase {
    func test_defaultConfig() {
        let config = MisttyConfig.default
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertEqual(config.fontFamily, "monospace")
    }

    func test_parsesValidTOML() throws {
        let toml = """
        font_size = 16
        font_family = "JetBrains Mono"
        """
        let config = try MisttyConfig.parse(toml)
        XCTAssertEqual(config.fontSize, 16)
        XCTAssertEqual(config.fontFamily, "JetBrains Mono")
    }

    func test_missingKeysUseDefaults() throws {
        let config = try MisttyConfig.parse("")
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertEqual(config.fontFamily, "monospace")
    }

    func test_invalidTOMLThrows() {
        XCTAssertThrowsError(try MisttyConfig.parse("font_size = !!!invalid"))
    }
}
```

**Step 2: Run to verify failure**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" \
  -only-testing:MisttyTests/MisttyConfigTests 2>&1 | tail -20
```

Expected: FAIL — `MisttyConfig` not found.

**Step 3: Implement**

`Mistty/Config/MisttyConfig.swift`:

```swift
import TOMLKit
import Foundation

struct MisttyConfig {
    var fontSize: Int = 13
    var fontFamily: String = "monospace"

    static let `default` = MisttyConfig()

    static func parse(_ toml: String) throws -> MisttyConfig {
        let table = try TOMLTable(string: toml)
        var config = MisttyConfig()
        if let size = table["font_size"]?.int { config.fontSize = size }
        if let family = table["font_family"]?.string { config.fontFamily = family }
        return config
    }

    static func load() -> MisttyConfig {
        let configURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mistty/config.toml")
        guard let contents = try? String(contentsOf: configURL) else { return .default }
        return (try? parse(contents)) ?? .default
    }
}
```

**Step 4: Run tests**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" \
  -only-testing:MisttyTests/MisttyConfigTests 2>&1 | tail -20
```

Expected: All 4 tests PASS.

**Step 5: Commit**

```bash
git add Mistty/Config/ MisttyTests/Config/
git commit -m "feat: config parser with TOML support"
```

---

### Task 8: Session / Tab / Pane model

**Files:**
- Create: `Mistty/Models/Protocols.swift`
- Create: `Mistty/Models/MisttyPane.swift`
- Create: `Mistty/Models/MisttyTab.swift`
- Create: `Mistty/Models/MisttySession.swift`
- Create: `Mistty/Models/SessionStore.swift`
- Create: `MisttyTests/Models/SessionStoreTests.swift`

**Step 1: Write failing tests**

`MisttyTests/Models/SessionStoreTests.swift`:

```swift
import XCTest
@testable import Mistty

final class SessionStoreTests: XCTestCase {
    var store: SessionStore!

    override func setUp() {
        store = SessionStore()
    }

    func test_startsEmpty() {
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func test_createSession() {
        let session = store.createSession(name: "myproject", directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(session.name, "myproject")
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.tabs[0].panes.count, 1)
    }

    func test_createSessionBecomesActive() {
        let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(store.activeSession?.id, session.id)
    }

    func test_closeSession() {
        let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
        store.closeSession(session)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.activeSession)
    }

    func test_addTabToSession() {
        let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
        session.addTab()
        XCTAssertEqual(session.tabs.count, 2)
    }

    func test_closeTab() {
        let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
        session.addTab()
        let firstTab = session.tabs[0]
        session.closeTab(firstTab)
        XCTAssertEqual(session.tabs.count, 1)
    }

    func test_splitPaneHorizontal() {
        let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
        let tab = session.tabs[0]
        tab.splitActivePane(direction: .horizontal)
        XCTAssertEqual(tab.panes.count, 2)
    }

    func test_splitPaneVertical() {
        let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
        let tab = session.tabs[0]
        tab.splitActivePane(direction: .vertical)
        XCTAssertEqual(tab.panes.count, 2)
    }
}
```

**Step 2: Run to verify failure**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" \
  -only-testing:MisttyTests/SessionStoreTests 2>&1 | tail -20
```

Expected: FAIL — types not found.

**Step 3: Implement protocols**

`Mistty/Models/Protocols.swift`:

```swift
import Foundation

protocol TerminalSession: AnyObject {
    var id: UUID { get }
    var name: String { get set }
    var tabs: [any TerminalTab] { get }
    var activeTab: (any TerminalTab)? { get set }
    func addTab()
    func closeTab(_ tab: any TerminalTab)
}

protocol TerminalTab: AnyObject {
    var id: UUID { get }
    var title: String { get set }
    var panes: [any TerminalPane] { get }
    var activePane: (any TerminalPane)? { get set }
    func splitActivePane(direction: SplitDirection)
}

protocol TerminalPane: AnyObject {
    var id: UUID { get }
    // Terminal surface binding added after spike informs the API
}

enum SplitDirection {
    case horizontal, vertical
}
```

**Step 4: Implement MisttyPane**

`Mistty/Models/MisttyPane.swift`:

```swift
import Foundation

@Observable
final class MisttyPane: TerminalPane {
    let id = UUID()
    // ghostty_surface_t surface — added in Task 9 once spike concludes
}
```

**Step 5: Implement MisttyTab**

`Mistty/Models/MisttyTab.swift`:

```swift
import Foundation

@Observable
final class MisttyTab: TerminalTab {
    let id = UUID()
    var title: String = "Shell"
    private(set) var panes: [any TerminalPane] = []
    var activePane: (any TerminalPane)?

    init() {
        let pane = MisttyPane()
        panes = [pane]
        activePane = pane
    }

    func splitActivePane(direction: SplitDirection) {
        let newPane = MisttyPane()
        panes.append(newPane)
        activePane = newPane
    }
}
```

**Step 6: Implement MisttySession**

`Mistty/Models/MisttySession.swift`:

```swift
import Foundation

@Observable
final class MisttySession: TerminalSession {
    let id = UUID()
    var name: String
    let directory: URL
    private(set) var tabs: [any TerminalTab] = []
    var activeTab: (any TerminalTab)?

    init(name: String, directory: URL) {
        self.name = name
        self.directory = directory
        addTab()
    }

    func addTab() {
        let tab = MisttyTab()
        tabs.append(tab)
        activeTab = tab
    }

    func closeTab(_ tab: any TerminalTab) {
        tabs.removeAll { $0.id == tab.id }
        if activeTab?.id == tab.id { activeTab = tabs.last }
    }
}
```

**Step 7: Implement SessionStore**

`Mistty/Models/SessionStore.swift`:

```swift
import Foundation

@Observable
final class SessionStore {
    private(set) var sessions: [MisttySession] = []
    var activeSession: MisttySession?

    @discardableResult
    func createSession(name: String, directory: URL) -> MisttySession {
        let session = MisttySession(name: name, directory: directory)
        sessions.append(session)
        activeSession = session
        return session
    }

    func closeSession(_ session: MisttySession) {
        sessions.removeAll { $0.id == session.id }
        if activeSession?.id == session.id { activeSession = sessions.last }
    }
}
```

**Step 8: Run tests**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" \
  -only-testing:MisttyTests/SessionStoreTests 2>&1 | tail -20
```

Expected: All 8 tests PASS.

**Step 9: Commit**

```bash
git add Mistty/Models/ MisttyTests/Models/
git commit -m "feat: session/tab/pane model with protocol abstractions"
```

---

### Task 9: Pane layout model

**Files:**
- Create: `Mistty/Models/PaneLayout.swift`
- Create: `MisttyTests/Models/PaneLayoutTests.swift`

**Step 1: Write failing tests**

`MisttyTests/Models/PaneLayoutTests.swift`:

```swift
import XCTest
@testable import Mistty

final class PaneLayoutTests: XCTestCase {
    func test_singlePaneHasOneLeaf() {
        let tab = MisttyTab()
        XCTAssertEqual(tab.layout.leaves.count, 1)
    }

    func test_splitHorizontalAddsSibling() {
        let tab = MisttyTab()
        let pane = tab.panes[0] as! MisttyPane
        tab.layout.split(pane: pane, direction: .horizontal)
        XCTAssertEqual(tab.layout.leaves.count, 2)
    }

    func test_splitVerticalAddsChild() {
        let tab = MisttyTab()
        let pane = tab.panes[0] as! MisttyPane
        tab.layout.split(pane: pane, direction: .vertical)
        XCTAssertEqual(tab.layout.leaves.count, 2)
        if case .split(let dir, _, _) = tab.layout.root {
            XCTAssertEqual(dir, .vertical)
        } else {
            XCTFail("Expected split at root")
        }
    }

    func test_splitDirectionIsRecorded() {
        let tab = MisttyTab()
        let pane = tab.panes[0] as! MisttyPane
        tab.layout.split(pane: pane, direction: .horizontal)
        if case .split(let dir, _, _) = tab.layout.root {
            XCTAssertEqual(dir, .horizontal)
        } else {
            XCTFail("Expected split at root")
        }
    }
}
```

**Step 2: Run to verify failure**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" \
  -only-testing:MisttyTests/PaneLayoutTests 2>&1 | tail -20
```

Expected: FAIL.

**Step 3: Implement PaneLayout**

`Mistty/Models/PaneLayout.swift`:

```swift
import Foundation

indirect enum PaneLayoutNode {
    case leaf(MisttyPane)
    case split(SplitDirection, PaneLayoutNode, PaneLayoutNode)
}

struct PaneLayout {
    var root: PaneLayoutNode

    init(pane: MisttyPane) {
        root = .leaf(pane)
    }

    var leaves: [MisttyPane] {
        collectLeaves(root)
    }

    private func collectLeaves(_ node: PaneLayoutNode) -> [MisttyPane] {
        switch node {
        case .leaf(let pane): return [pane]
        case .split(_, let a, let b): return collectLeaves(a) + collectLeaves(b)
        }
    }

    mutating func split(pane: MisttyPane, direction: SplitDirection) {
        let newPane = MisttyPane()
        root = insertSplit(root, target: pane.id, direction: direction, newPane: newPane)
    }

    private func insertSplit(
        _ node: PaneLayoutNode,
        target: UUID,
        direction: SplitDirection,
        newPane: MisttyPane
    ) -> PaneLayoutNode {
        switch node {
        case .leaf(let p) where p.id == target:
            return .split(direction, .leaf(p), .leaf(newPane))
        case .leaf:
            return node
        case .split(let dir, let a, let b):
            return .split(dir,
                insertSplit(a, target: target, direction: direction, newPane: newPane),
                insertSplit(b, target: target, direction: direction, newPane: newPane))
        }
    }
}
```

**Step 4: Add layout to MisttyTab**

Modify `Mistty/Models/MisttyTab.swift` — add a `layout` property:

```swift
// Add this property to MisttyTab:
var layout: PaneLayout

// Update init():
init() {
    let pane = MisttyPane()
    let layout = PaneLayout(pane: pane)
    self.layout = layout
    panes = [pane]
    activePane = pane
}

// Update splitActivePane:
func splitActivePane(direction: SplitDirection) {
    guard let active = activePane as? MisttyPane else { return }
    layout.split(pane: active, direction: direction)
    panes = layout.leaves
    activePane = layout.leaves.last
}
```

**Step 5: Run tests**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" \
  -only-testing:MisttyTests/PaneLayoutTests 2>&1 | tail -20
```

Expected: All 4 tests PASS.

**Step 6: Run all tests so far**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: All tests PASS.

**Step 7: Commit**

```bash
git add Mistty/Models/PaneLayout.swift MisttyTests/Models/PaneLayoutTests.swift
git commit -m "feat: recursive pane layout model"
```

---

### Task 10: Terminal surface view

> ⚠️ Adjust this task based on `docs/spike/conclusions.md`. The wrapper structure below is a starting point.

**Files:**
- Create: `Mistty/Views/Terminal/TerminalSurfaceView.swift`
- Create: `Mistty/Views/Terminal/PaneView.swift`
- Create: `Mistty/Views/Terminal/PaneLayoutView.swift`

**Step 1: Implement NSViewRepresentable**

`Mistty/Views/Terminal/TerminalSurfaceView.swift`:

```swift
import SwiftUI
import AppKit

struct TerminalSurfaceView: NSViewRepresentable {
    let pane: MisttyPane

    func makeNSView(context: Context) -> TerminalNSView {
        TerminalNSView(pane: pane)
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
        // Handle focus and resize — fill in based on spike conclusions
    }
}

// TerminalNSView wraps a ghostty_surface_t — implement based on spike findings
final class TerminalNSView: NSView {
    let pane: MisttyPane

    init(pane: MisttyPane) {
        self.pane = pane
        super.init(frame: .zero)
        // TODO: initialize ghostty surface using findings from docs/spike/conclusions.md
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // TODO: forward to ghostty surface
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // TODO: notify ghostty surface of resize
    }
}
```

**Step 2: Implement PaneView**

`Mistty/Views/Terminal/PaneView.swift`:

```swift
import SwiftUI

struct PaneView: View {
    let pane: MisttyPane
    let isActive: Bool

    var body: some View {
        TerminalSurfaceView(pane: pane)
            .overlay(alignment: .topLeading) {
                if isActive {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}
```

**Step 3: Implement PaneLayoutView**

`Mistty/Views/Terminal/PaneLayoutView.swift`:

```swift
import SwiftUI

struct PaneLayoutView: View {
    let node: PaneLayoutNode
    let activePane: MisttyPane?

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneView(pane: pane, isActive: activePane?.id == pane.id)
        case .split(.horizontal, let a, let b):
            HSplitView {
                PaneLayoutView(node: a, activePane: activePane)
                PaneLayoutView(node: b, activePane: activePane)
            }
        case .split(.vertical, let a, let b):
            VSplitView {
                PaneLayoutView(node: a, activePane: activePane)
                PaneLayoutView(node: b, activePane: activePane)
            }
        }
    }
}
```

**Step 4: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`

**Step 5: Manual test**

Open the app. Verify a terminal renders and accepts keyboard input.

**Step 6: Commit**

```bash
git add Mistty/Views/Terminal/
git commit -m "feat: terminal surface view and split pane layout view"
```

---

### Task 11: Tab bar

**Files:**
- Create: `Mistty/Views/TabBar/TabBarView.swift`

**Step 1: Implement**

`Mistty/Views/TabBar/TabBarView.swift`:

```swift
import SwiftUI

struct TabBarView: View {
    @Bindable var session: MisttySession

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.tabs as! [MisttyTab], id: \.id) { tab in
                        TabBarItem(
                            tab: tab,
                            isActive: session.activeTab?.id == tab.id,
                            onSelect: { session.activeTab = tab },
                            onClose: { session.closeTab(tab) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Button(action: { session.addTab() }) {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(height: 36)
        .background(.bar)
    }
}

struct TabBarItem: View {
    @Bindable var tab: MisttyTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)

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

**Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`

**Step 3: Commit**

```bash
git add Mistty/Views/TabBar/
git commit -m "feat: tab bar"
```

---

### Task 12: Sidebar

**Files:**
- Create: `Mistty/Views/Sidebar/SidebarView.swift`

**Step 1: Implement**

`Mistty/Views/Sidebar/SidebarView.swift`:

```swift
import SwiftUI

struct SidebarView: View {
    @Bindable var store: SessionStore

    var body: some View {
        List {
            ForEach(store.sessions, id: \.id) { session in
                SessionRowView(session: session, store: store)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, idealWidth: 220)
    }
}

struct SessionRowView: View {
    @Bindable var session: MisttySession
    @Bindable var store: SessionStore
    @State private var isExpanded = true

    var isActive: Bool { store.activeSession?.id == session.id }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(session.tabs as! [MisttyTab], id: \.id) { tab in
                HStack {
                    Text(tab.title)
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.leading, 8)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.activeSession = session
                    session.activeTab = tab
                }
            }
        } label: {
            Text(session.name)
                .fontWeight(isActive ? .semibold : .regular)
                .contentShape(Rectangle())
                .onTapGesture { store.activeSession = session }
        }
    }
}
```

**Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

**Step 3: Commit**

```bash
git add Mistty/Views/Sidebar/
git commit -m "feat: sidebar with collapsible session tree"
```

---

### Task 13: Services — Zoxide and SSH config

**Files:**
- Create: `Mistty/Services/ZoxideService.swift`
- Create: `Mistty/Services/SSHConfigService.swift`
- Create: `MisttyTests/Services/SSHConfigServiceTests.swift`

**Step 1: Write failing tests for SSH config parser**

`MisttyTests/Services/SSHConfigServiceTests.swift`:

```swift
import XCTest
@testable import Mistty

final class SSHConfigServiceTests: XCTestCase {
    func test_parsesHostEntries() {
        let config = """
        Host myserver
            HostName 192.168.1.1
            User admin

        Host dev
            HostName dev.example.com
        """
        let hosts = SSHConfigService.parse(config)
        XCTAssertEqual(hosts.count, 2)
        XCTAssertEqual(hosts[0].alias, "myserver")
        XCTAssertEqual(hosts[1].alias, "dev")
    }

    func test_ignoresWildcardHosts() {
        let config = "Host *\n    ServerAliveInterval 60\n"
        let hosts = SSHConfigService.parse(config)
        XCTAssertTrue(hosts.isEmpty)
    }

    func test_capturesHostName() {
        let config = "Host mybox\n    HostName 10.0.0.1\n"
        let hosts = SSHConfigService.parse(config)
        XCTAssertEqual(hosts[0].hostname, "10.0.0.1")
    }

    func test_emptyConfigReturnsEmpty() {
        XCTAssertTrue(SSHConfigService.parse("").isEmpty)
    }
}
```

**Step 2: Run to verify failure**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" \
  -only-testing:MisttyTests/SSHConfigServiceTests 2>&1 | tail -20
```

Expected: FAIL.

**Step 3: Implement SSH config service**

`Mistty/Services/SSHConfigService.swift`:

```swift
import Foundation

struct SSHHost {
    let alias: String
    let hostname: String?
}

struct SSHConfigService {
    static func parse(_ content: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var currentAlias: String?
        var currentHostname: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if lower.hasPrefix("host ") {
                if let alias = currentAlias, !alias.contains("*") {
                    hosts.append(SSHHost(alias: alias, hostname: currentHostname))
                }
                currentAlias = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                currentHostname = nil
            } else if lower.hasPrefix("hostname ") {
                currentHostname = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            }
        }

        if let alias = currentAlias, !alias.contains("*") {
            hosts.append(SSHHost(alias: alias, hostname: currentHostname))
        }

        return hosts
    }

    static func loadHosts() -> [SSHHost] {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let content = try? String(contentsOf: url) else { return [] }
        return parse(content)
    }
}
```

**Step 4: Implement Zoxide service**

`Mistty/Services/ZoxideService.swift`:

```swift
import Foundation

struct ZoxideService {
    static func recentDirectories() async -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zoxide", "query", "-l"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }
        } catch {
            return [] // zoxide not installed — silently omit
        }
    }
}
```

**Step 5: Run tests**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" \
  -only-testing:MisttyTests/SSHConfigServiceTests 2>&1 | tail -20
```

Expected: All 4 tests PASS.

**Step 6: Commit**

```bash
git add Mistty/Services/ MisttyTests/Services/
git commit -m "feat: zoxide and SSH config services"
```

---

### Task 14: Session manager overlay

**Files:**
- Create: `Mistty/Views/SessionManager/SessionManagerViewModel.swift`
- Create: `Mistty/Views/SessionManager/SessionManagerView.swift`

**Step 1: Implement view model**

`Mistty/Views/SessionManager/SessionManagerViewModel.swift`:

```swift
import Foundation

enum SessionManagerItem {
    case runningSession(MisttySession)
    case directory(URL)
    case sshHost(SSHHost)

    var displayName: String {
        switch self {
        case .runningSession(let s): return "▶ \(s.name)"
        case .directory(let u): return u.path
        case .sshHost(let h): return "⌁ \(h.alias)"
        }
    }
}

@Observable
final class SessionManagerViewModel {
    var query = ""
    private var allItems: [SessionManagerItem] = []
    var filteredItems: [SessionManagerItem] = []
    var selectedIndex = 0

    let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    func load() async {
        let dirs = await ZoxideService.recentDirectories()
        let sshHosts = SSHConfigService.loadHosts()

        var items: [SessionManagerItem] = []
        items += store.sessions.map { .runningSession($0) }
        items += dirs.map { .directory($0) }
        items += sshHosts.map { .sshHost($0) }

        allItems = items
        applyFilter()
    }

    func updateQuery(_ newQuery: String) {
        query = newQuery
        applyFilter()
    }

    private func applyFilter() {
        if query.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
            }
        }
        selectedIndex = 0
    }

    func moveUp() { selectedIndex = max(0, selectedIndex - 1) }
    func moveDown() { selectedIndex = min(filteredItems.count - 1, selectedIndex + 1) }

    func confirmSelection() {
        guard selectedIndex < filteredItems.count else { return }
        switch filteredItems[selectedIndex] {
        case .runningSession(let session):
            store.activeSession = session
        case .directory(let url):
            store.createSession(name: url.lastPathComponent, directory: url)
        case .sshHost:
            break // post-MVP
        }
    }
}
```

**Step 2: Implement overlay view**

`Mistty/Views/SessionManager/SessionManagerView.swift`:

```swift
import SwiftUI

struct SessionManagerView: View {
    @Bindable var vm: SessionManagerViewModel
    @Binding var isPresented: Bool
    @State private var queryText = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search sessions, directories, hosts...", text: $queryText)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .onChange(of: queryText) { vm.updateQuery(queryText) }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(vm.filteredItems.enumerated()), id: \.offset) { index, item in
                            HStack {
                                Text(item.displayName)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(index == vm.selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.selectedIndex = index
                                vm.confirmSelection()
                                isPresented = false
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: vm.selectedIndex) { proxy.scrollTo(vm.selectedIndex, anchor: .center) }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20)
        .onKeyPress(.upArrow) { vm.moveUp(); return .handled }
        .onKeyPress(.downArrow) { vm.moveDown(); return .handled }
        .onKeyPress(.return) { vm.confirmSelection(); isPresented = false; return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .task { await vm.load() }
    }
}
```

**Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`

**Step 4: Commit**

```bash
git add Mistty/Views/SessionManager/
git commit -m "feat: session manager overlay"
```

---

### Task 15: Root view — wire everything together

**Files:**
- Modify: `Mistty/App/ContentView.swift`
- Modify: `Mistty/App/MisttyApp.swift`

**Step 1: Implement ContentView**

`Mistty/App/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @State var store = SessionStore()
    @AppStorage("sidebarVisible") var sidebarVisible = true
    @State var showingSessionManager = false

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(store: store)
                Divider()
            }

            Group {
                if let session = store.activeSession,
                   let tab = session.activeTab as? MisttyTab {
                    VStack(spacing: 0) {
                        TabBarView(session: session)
                        Divider()
                        PaneLayoutView(
                            node: tab.layout.root,
                            activePane: tab.activePane as? MisttyPane
                        )
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("No active session")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Press ⌘J to open or create a session")
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay {
            if showingSessionManager {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showingSessionManager = false }

                SessionManagerView(
                    vm: SessionManagerViewModel(store: store),
                    isPresented: $showingSessionManager
                )
            }
        }
    }
}
```

**Step 2: Implement MisttyApp with commands**

`Mistty/App/MisttyApp.swift`:

```swift
import SwiftUI

@main
struct MisttyApp: App {
    @AppStorage("sidebarVisible") var sidebarVisible = true

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()

                Button("Toggle Sidebar") {
                    sidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("New Tab") {
                    // Posted via NotificationCenter — ContentView observes
                    NotificationCenter.default.post(name: .misttyNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Split Pane Horizontally") {
                    NotificationCenter.default.post(name: .mistrySplitHorizontal, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Split Pane Vertically") {
                    NotificationCenter.default.post(name: .mistrySplitVertical, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Session Manager") {
                    NotificationCenter.default.post(name: .mistrySessionManager, object: nil)
                }
                .keyboardShortcut("j", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let misttyNewTab = Notification.Name("misttyNewTab")
    static let mistrySplitHorizontal = Notification.Name("mistrySplitHorizontal")
    static let mistrySplitVertical = Notification.Name("mistrySplitVertical")
    static let mistrySessionManager = Notification.Name("mistrySessionManager")
}
```

**Step 3: Observe notifications in ContentView**

Add to `ContentView.body` after `.overlay`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyNewTab)) { _ in
    store.activeSession?.addTab()
}
.onReceive(NotificationCenter.default.publisher(for: .mistrySplitHorizontal)) { _ in
    (store.activeSession?.activeTab as? MisttyTab)?.splitActivePane(direction: .horizontal)
}
.onReceive(NotificationCenter.default.publisher(for: .mistrySplitVertical)) { _ in
    (store.activeSession?.activeTab as? MisttyTab)?.splitActivePane(direction: .vertical)
}
.onReceive(NotificationCenter.default.publisher(for: .mistrySessionManager)) { _ in
    showingSessionManager = true
}
```

**Step 4: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`

**Step 5: Run all tests**

```bash
xcodebuild test -scheme Mistty -destination "platform=macOS" 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

Expected: All tests PASS.

**Step 6: Manual smoke test checklist**

- [ ] App launches without crash
- [ ] `cmd+j` opens session manager overlay
- [ ] Typing in session manager filters the list
- [ ] Arrow keys navigate the list
- [ ] Enter on a directory opens a new session with a working terminal
- [ ] Session appears in sidebar
- [ ] `cmd+t` adds a new tab; appears in tab bar and sidebar
- [ ] `cmd+d` splits pane horizontally; both panes show independent terminals
- [ ] `cmd+shift+d` splits pane vertically
- [ ] `cmd+s` hides the sidebar; `cmd+s` again shows it

**Step 7: Final commit**

```bash
git add Mistty/App/
git commit -m "feat: wire root view — MVP complete"
```

---

## Post-MVP

Deferred features (from design doc):
- Session persistence via background daemon
- Save/restore layouts
- Window mode (`cmd+x`) — pane resize, swap, break, merge, rotate
- Copy mode — vim-style scrollback navigation
- Bell activity indicators in sidebar
- Tab rename
- Preferences pane
- Live config reload
- SSH session creation from session manager
