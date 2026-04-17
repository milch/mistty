# Chrome Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land a coherent UI polish pass across Mistty's native chrome — hidden macOS title bar, tighter tab bar that auto-hides at ≤1 tab, animated sidebar slide, active-pane-aware sidebar labels, bundled Nerd Font process icons, and SFSymbols in the session manager — as six independently mergeable phases.

**Architecture:** Six phased chunks with clear boundaries. Phases 1–2 handle window chrome + tab bar layout (dependent pair). Phases 3–6 are independently mergeable: sidebar animation (pure cosmetic), session label model (new `customName` field + `sidebarLabel` computed property), process icon rendering (bundled Nerd Font + static mapping), session manager icon swap (Unicode → SFSymbols). Each phase ships with its own commits and tests where testable.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit, Swift Package Manager (SPM), XCTest. macOS 14+. Native font registration via `CTFontManagerRegisterFontsForURL`.

**Spec:** `docs/superpowers/specs/2026-04-16-chrome-polish-design.md`

---

## File Structure

### New files

- `Mistty/Support/ProcessIcon.swift` — process-name → Nerd Font glyph mapping. Pure data + lookup. No UI dependency.
- `Mistty/Support/SSHHostParser.swift` — parse an SSH command string (e.g. `"ssh user@host -p 22"`) into a displayable host token. Pure string utility.
- `Mistty/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf` — bundled Symbols-only Nerd Font (downloaded in Task 5.1).
- `MisttyTests/Support/ProcessIconTests.swift` — unit tests for icon mapping.
- `MisttyTests/Support/SSHHostParserTests.swift` — unit tests for host parser.
- `MisttyTests/Models/MisttySessionSidebarLabelTests.swift` — unit tests for `MisttySession.sidebarLabel` priority chain.

### Modified files

- `Mistty/App/MisttyApp.swift` — add `.windowStyle(.hiddenTitleBar)`; register bundled font in `init()`.
- `Mistty/App/ContentView.swift` — apply traffic-light clearance insets for the four sidebar × tab-bar visibility cases.
- `Mistty/Views/TabBar/TabBarView.swift` — restyle to subtle-pill 28px.
- `Mistty/Models/MisttySession.swift` — add `customName: String?` and `sidebarLabel` computed property.
- `Mistty/Views/Sidebar/SidebarView.swift` — use `sidebarLabel`; add process icon views.
- `Mistty/Views/SessionManager/SessionManagerView.swift` — add SFSymbol icon column.
- `Mistty/Views/SessionManager/SessionManagerViewModel.swift` — set `customName` on plain-text session creation; update `matchableFields` prefix lengths after Unicode prefixes are dropped.
- `Mistty/Models/SessionStore.swift` — add `customName` parameter to `createSession`.
- `Package.swift` — add `resources: [.process("Resources/Fonts")]` to the Mistty target.
- `MisttyTests/Views/SessionManagerViewModelTests.swift` — update expectations after Unicode prefixes are stripped.

---

## Conventions for this plan

- **Working directory:** repo root (`/Users/manu/Developer/mistty` or the active worktree's root). All commands assume `pwd` is the repo root.
- **Build/test commands:** `swift build` and `swift test` from the repo root. Running a specific test: `swift test --filter MisttyTests.ProcessIconTests/testGlyphForKnownProcess`.
- **Commits:** one per task (or per logical substep as specified), using Conventional Commits. Every commit message includes the `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` footer.
- **TDD:** unit-testable logic (mapping tables, parsers, computed properties) gets a failing test first. Pure-visual SwiftUI changes are verified manually by running the app.

---

# Phase 1 — Window chrome

### Task 1.1: Hide macOS title bar via `WindowGroup` style

**Files:**
- Modify: `Mistty/App/MisttyApp.swift`

- [ ] **Step 1: Add hidden title bar style to the scene.**

In `Mistty/App/MisttyApp.swift`, locate the `WindowGroup { ... }` block inside `var body: some Scene { ... }`. Append the `.windowStyle(.hiddenTitleBar)` modifier after the existing `WindowGroup { ... }` closing brace and before `.commands { ... }`:

```swift
var body: some Scene {
  WindowGroup {
    ContentView(store: store)
      .onAppear {
        if ipcListener == nil {
          let service = MisttyIPCService(store: store)
          let listener = IPCListener(service: service)
          listener.start()
          ipcListener = listener
        }
      }
  }
  .windowStyle(.hiddenTitleBar)
  .commands {
    // ...unchanged...
  }
  // ...unchanged...
}
```

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: clean build, no errors.

- [ ] **Step 3: Manually verify.**

Run the app (Xcode-Run or `swift run Mistty`). Confirm:
- Traffic lights (red/yellow/green) are still visible at top-left.
- No visible title bar strip (no "Mistty" title shown).
- Window is still draggable by the top strip.

- [ ] **Step 4: Commit.**

```bash
git add Mistty/App/MisttyApp.swift
git commit -m "$(cat <<'EOF'
feat(ui): hide macOS title bar on main window

Traffic lights remain floating top-left via .hiddenTitleBar.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.2: Add traffic-light clearance insets

**Files:**
- Modify: `Mistty/App/ContentView.swift`
- Modify: `Mistty/Views/Sidebar/SidebarView.swift`

**Context:** With the title bar hidden, floating traffic lights occupy roughly the leading 72pt × top 28pt region of the window. We need to inset content so nothing collides with them. Four cases by `sidebarVisible` × `tabs.count > 1` — see spec Phase 1.

- [ ] **Step 1: Add a top inset to the sidebar content.**

In `Mistty/Views/Sidebar/SidebarView.swift`, modify `SidebarView.body` to apply `.padding(.top, 28)` to the `List`:

```swift
struct SidebarView: View {
  @Bindable var store: SessionStore
  @Binding var width: CGFloat

  var body: some View {
    List {
      ForEach(store.sessions) { session in
        SessionRowView(session: session, store: store)
      }
    }
    .listStyle(.sidebar)
    .padding(.top, 28)
    .frame(width: width)
    .overlay(alignment: .trailing) {
      SidebarDragHandle(width: $width)
    }
  }
}
```

- [ ] **Step 2: Add leading + top insets to the main content column for the "no sidebar, no tab bar" case.**

We'll apply insets conditionally in `ContentView.mainContent`. For now, introduce two helpers and a modifier that applies the correct inset. In `Mistty/App/ContentView.swift`, inside the `ContentView` struct, add these computed properties near the `body` section:

```swift
private var trafficLightLeadingInset: CGFloat {
  sidebarVisible ? 0 : 72
}

private var tabBarVisible: Bool {
  (store.activeSession?.tabs.count ?? 0) > 1
}

private var contentTopInset: CGFloat {
  // When the tab bar is showing, it occupies the 28pt strip.
  // Otherwise the terminal needs its own top padding to clear traffic lights.
  tabBarVisible ? 0 : 28
}
```

Note: `tabBarVisible` / `contentTopInset` will be used by Phase 2 once auto-hide lands. For Phase 1 we assume the tab bar is always visible in the layout — so `contentTopInset` currently always returns 0. Phase 2 will flip this. For now, just wire the leading inset.

In `Mistty/App/ContentView.swift`, locate `mainContent` and modify the tab-bar / main-column branch (the `Group` that contains `VStack { TabBarView; Divider; ZStack { ... } }`) to apply the leading inset when the sidebar is hidden:

```swift
@ViewBuilder
private var mainContent: some View {
  HStack(spacing: 0) {
    if sidebarVisible {
      SidebarView(
        store: store,
        width: Binding(
          get: { CGFloat(sidebarWidth) },
          set: { sidebarWidth = Double($0) }
        ))
      Divider()
    }

    Group {
      if let session = store.activeSession,
        let tab = session.activeTab
      {
        VStack(spacing: 0) {
          TabBarView(session: session)
          Divider()
          // ... existing ZStack unchanged ...
          let joinPickTabNames = session.tabs
            .filter { $0.id != tab.id }
            .map { $0.displayTitle }
          ZStack(alignment: .bottom) {
            if let zoomedPane = tab.zoomedPane {
              PaneView(
                pane: zoomedPane,
                isActive: true,
                isWindowModeActive: tab.isWindowModeActive,
                isZoomed: true,
                copyModeState: (zoomedPane.id == tab.activePane?.id) ? tab.copyModeState : nil,
                windowModeState: tab.windowModeState,
                joinPickTabNames: joinPickTabNames,
                paneCount: tab.panes.count,
                onClose: { closePane(zoomedPane) },
                onSelect: {}
              )
            } else {
              PaneLayoutView(
                node: tab.layout.root,
                activePane: tab.activePane,
                isWindowModeActive: tab.isWindowModeActive,
                copyModeState: tab.copyModeState,
                copyModePaneID: tab.activePane?.id,
                windowModeState: tab.windowModeState,
                joinPickTabNames: joinPickTabNames,
                paneCount: tab.panes.count,
                onClosePane: { pane in closePane(pane) },
                onSelectPane: { pane in tab.activePane = pane }
              )
            }
            if tab.windowModeState != .inactive {
              WindowModeHints(
                isJoinPick: tab.windowModeState == .joinPick,
                tabNames: joinPickTabNames,
                paneCount: tab.panes.count
              )
              .padding(6)
              .allowsHitTesting(false)
            }
          }
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
    .padding(.leading, trafficLightLeadingInset)
  }
  .onAppear {
    DispatchQueue.main.async {
      if let window = NSApplication.shared.keyWindow {
        _ = store.registerWindow(window)
      }
    }
    if ctrlNavMonitor == nil {
      installCtrlNavMonitor()
    }
    if closeMonitor == nil {
      installCloseMonitor()
    }
  }
  .onDisappear {
    DispatchQueue.main.async { [store] in
      for tracked in store.trackedWindows where !tracked.window.isVisible {
        store.unregisterWindow(tracked.window)
      }
    }
    removeKeyMonitor()
    removeWindowModeMonitor()
    removeCopyModeMonitor()
    removeCtrlNavMonitor()
    removeCloseMonitor()
    store.activeSession?.activeTab?.windowModeState = .inactive
    if store.activeSession?.activeTab?.isCopyModeActive == true {
      exitCopyMode()
    }
    showingSessionManager = false
  }
}
```

The only structural addition is `.padding(.leading, trafficLightLeadingInset)` on the `Group`. Keep everything else identical.

- [ ] **Step 3: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Manually verify.**

Launch the app. Test each of the four cases:
1. Sidebar visible + multi-tab: traffic lights sit over sidebar top edge, sidebar first row pushed below them. Tab bar on right column sits flush at y=0, unoccluded. ✅
2. Sidebar visible + single tab: tab bar still visible in this phase (auto-hide lands in Phase 2). Lights sit over sidebar. ✅
3. Sidebar hidden + multi-tab (cmd+S to toggle): lights float over the tab bar's leading 72pt. Tab bar's leftmost tab pushed right by 72pt. No overlap. ✅
4. Sidebar hidden + single tab: same as (3) in this phase. ✅

- [ ] **Step 5: Commit.**

```bash
git add Mistty/App/ContentView.swift Mistty/Views/Sidebar/SidebarView.swift
git commit -m "$(cat <<'EOF'
feat(ui): inset content so floating traffic lights have clearance

Sidebar first row gets 28pt top padding; main column gets 72pt
leading padding when the sidebar is hidden.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Phase 2 — Tab bar restyle + auto-hide

### Task 2.1: Restyle tab bar to subtle pill, 28px

**Files:**
- Modify: `Mistty/Views/TabBar/TabBarView.swift`

- [ ] **Step 1: Replace `TabBarView` body with the 28px, tighter layout.**

In `Mistty/Views/TabBar/TabBarView.swift`, replace the `TabBarView` struct's `body` with:

```swift
var body: some View {
  HStack(spacing: 0) {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        ForEach(session.tabs) { tab in
          TabBarItem(
            tab: tab,
            isActive: session.activeTab?.id == tab.id,
            onSelect: { session.activeTab = tab },
            onClose: { session.closeTab(tab) }
          )
        }
      }
      .padding(.horizontal, 6)
    }

    Button(action: { session.addTab() }) {
      Image(systemName: "plus")
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.plain)
    .padding(.trailing, 4)
  }
  .frame(height: 28)
  .background(.bar)
}
```

Changes vs existing: outer `.frame(height: 36)` → `28`, inner padding `4` → `6`, plus-button frame `28` → `24`.

- [ ] **Step 2: Replace `TabBarItem` body with the subtle pill style.**

In the same file, replace the `TabBarItem` struct's `body` with:

```swift
var body: some View {
  HStack(spacing: 4) {
    if tab.hasBell {
      Circle()
        .fill(Color.orange)
        .frame(width: 6, height: 6)
    }

    if isEditing {
      TextField(
        "Tab name", text: $editText,
        onCommit: {
          tab.customTitle = editText.isEmpty ? nil : editText
          isEditing = false
        }
      )
      .textFieldStyle(.plain)
      .font(.system(size: 11))
      .focused($editFocused)
      .frame(maxWidth: 120)
      .onAppear { editFocused = true }
    } else {
      Text(tab.displayTitle)
        .font(.system(size: 11))
        .foregroundStyle(isActive ? .primary : .secondary)
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
  .padding(.vertical, 4)
  .background(isActive ? Color.primary.opacity(0.08) : Color.clear)
  .cornerRadius(5)
  .onTapGesture { onSelect() }
  .onReceive(NotificationCenter.default.publisher(for: .misttyRenameTab)) { _ in
    if isActive {
      editText = tab.displayTitle
      isEditing = true
    }
  }
}
```

Changes vs existing: font `12` → `11`, vertical padding `6` → `4`, corner radius `6` → `5`, active background `Color.accentColor.opacity(0.15)` → `Color.primary.opacity(0.08)`, inactive text foreground explicitly `.secondary`.

- [ ] **Step 3: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Manually verify.**

Launch the app, open a session with ≥2 tabs. Verify:
- Bar is visibly shorter (28pt vs previous 36pt).
- Active tab has subtle grey background, not accent color.
- Inactive tabs' text is dimmer (`.secondary`).
- Tab close `x` still only appears on the active tab.
- Double-click on tab title still enters rename.
- Bell dot still renders for tabs with background activity.

- [ ] **Step 5: Commit.**

```bash
git add Mistty/Views/TabBar/TabBarView.swift
git commit -m "$(cat <<'EOF'
feat(ui): subtle-pill tab bar style at 28px

Smaller height, muted active background using .primary.opacity(0.08),
inactive tabs dimmed via .secondary foreground.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.2: Auto-hide tab bar when `tabs.count <= 1`

**Files:**
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Gate the tab bar + divider on tab count with a transition.**

In `Mistty/App/ContentView.swift`, inside `mainContent`'s `VStack(spacing: 0)` block (the branch where a session + tab exist), wrap `TabBarView` and its trailing `Divider` in a conditional with a transition. Replace:

```swift
VStack(spacing: 0) {
  TabBarView(session: session)
  Divider()
  let joinPickTabNames = session.tabs
    .filter { $0.id != tab.id }
    .map { $0.displayTitle }
```

with:

```swift
VStack(spacing: 0) {
  if session.tabs.count > 1 {
    TabBarView(session: session)
      .transition(.asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity),
        removal: .move(edge: .top).combined(with: .opacity)
      ))
    Divider()
      .transition(.opacity)
  }
  let joinPickTabNames = session.tabs
    .filter { $0.id != tab.id }
    .map { $0.displayTitle }
```

Then, just before the closing brace of this `VStack`, attach the animation:

Find the closing brace of that `VStack(spacing: 0) { ... }` and append:

```swift
.animation(.easeInOut(duration: 0.15), value: session.tabs.count)
```

So the structure becomes:

```swift
VStack(spacing: 0) {
  if session.tabs.count > 1 {
    TabBarView(session: session)
      .transition(...)
    Divider().transition(.opacity)
  }
  // ... let joinPickTabNames = ...
  // ... ZStack { ... }
}
.animation(.easeInOut(duration: 0.15), value: session.tabs.count)
```

- [ ] **Step 2: Flip `contentTopInset` to apply when tab bar is hidden.**

Also in `ContentView.swift`: the `contentTopInset` helper was added in Task 1.2 but unused. Now apply it. Still inside `mainContent`, attach `.padding(.top, contentTopInset)` to the `Group` containing `.padding(.leading, trafficLightLeadingInset)`. Final chain on the Group becomes:

```swift
.padding(.leading, trafficLightLeadingInset)
.padding(.top, contentTopInset)
```

- [ ] **Step 3: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Manually verify.**

Launch the app:
1. Fresh session has 1 tab → tab bar is NOT visible. Terminal content should have a 28pt top gap so traffic lights have clearance. ✅
2. Press ⌘T to add a tab → tab bar slides down from the top over ~150ms, showing both tabs. ✅
3. Close one tab → tab bar slides up and disappears smoothly. ✅
4. Toggle sidebar (⌘S) while on a single-tab session: leading 72pt inset still applied, top inset still present. ✅

- [ ] **Step 5: Commit.**

```bash
git add Mistty/App/ContentView.swift
git commit -m "$(cat <<'EOF'
feat(ui): auto-hide tab bar when session has a single tab

Slides in/out with 150ms ease transition when tab count crosses 1.
Main content gets a compensating top inset so traffic lights clear
the terminal surface when the bar is hidden.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Phase 3 — Sidebar slide animation

### Task 3.1: Animate sidebar show/hide

**Files:**
- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Wrap the sidebar toggle in `withAnimation`.**

In `Mistty/App/MisttyApp.swift`, locate the `Button("Toggle Sidebar") { sidebarVisible.toggle() }` and change the action body:

```swift
Button("Toggle Sidebar") {
  withAnimation(.easeInOut(duration: 0.18)) {
    sidebarVisible.toggle()
  }
}
.keyboardShortcut("s", modifiers: .command)
```

- [ ] **Step 2: Add a transition to the sidebar branch in `ContentView`.**

In `Mistty/App/ContentView.swift`, inside `mainContent` where the `if sidebarVisible { SidebarView(...); Divider() }` branch lives, wrap the branch so it transitions as a unit. Replace:

```swift
if sidebarVisible {
  SidebarView(
    store: store,
    width: Binding(
      get: { CGFloat(sidebarWidth) },
      set: { sidebarWidth = Double($0) }
    ))
  Divider()
}
```

with:

```swift
if sidebarVisible {
  HStack(spacing: 0) {
    SidebarView(
      store: store,
      width: Binding(
        get: { CGFloat(sidebarWidth) },
        set: { sidebarWidth = Double($0) }
      ))
    Divider()
  }
  .transition(.move(edge: .leading))
}
```

The enclosing `HStack` is necessary so SwiftUI treats the sidebar + its divider as a single transitioning unit.

- [ ] **Step 3: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Manually verify.**

Launch the app. Press ⌘S repeatedly:
- Sidebar slides off to the left over ~180ms when hidden.
- Slides back in from the left over ~180ms when shown.
- Main content reflows smoothly — no jank or abrupt jump.

- [ ] **Step 5: Commit.**

```bash
git add Mistty/App/MisttyApp.swift Mistty/App/ContentView.swift
git commit -m "$(cat <<'EOF'
feat(ui): animate sidebar show/hide with 180ms slide

Toggle wraps in withAnimation(.easeInOut(0.18)); sidebar branch uses
.transition(.move(edge: .leading)) on a unit containing the list +
divider so they move together.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Phase 4 — Session label model

This phase is TDD: write the SSH parser and the `sidebarLabel` priority chain against unit tests first, then wire them up in the sidebar view.

### Task 4.1: Test + implement SSH host parser

**Files:**
- Create: `Mistty/Support/SSHHostParser.swift`
- Create: `MisttyTests/Support/SSHHostParserTests.swift`

- [ ] **Step 1: Create the test file with failing cases.**

Create `MisttyTests/Support/SSHHostParserTests.swift`:

```swift
import XCTest

@testable import Mistty

final class SSHHostParserTests: XCTestCase {
  func test_simpleHost() {
    XCTAssertEqual(SSHHostParser.host(from: "ssh mybox"), "mybox")
  }

  func test_userAtHost() {
    XCTAssertEqual(SSHHostParser.host(from: "ssh manu@mybox"), "mybox")
  }

  func test_withPortFlag() {
    XCTAssertEqual(SSHHostParser.host(from: "ssh -p 2222 mybox"), "mybox")
  }

  func test_withPortFlagAndUser() {
    XCTAssertEqual(SSHHostParser.host(from: "ssh -p 2222 manu@dev.example.com"), "dev.example.com")
  }

  func test_customSSHBinaryPrefix() {
    XCTAssertEqual(SSHHostParser.host(from: "/usr/bin/ssh -A mybox"), "mybox")
  }

  func test_emptyReturnsNil() {
    XCTAssertNil(SSHHostParser.host(from: ""))
  }

  func test_noHostReturnsNil() {
    XCTAssertNil(SSHHostParser.host(from: "ssh -p 22"))
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail (type doesn't exist).**

Run: `swift test --filter MisttyTests.SSHHostParserTests`
Expected: FAIL with compilation error ("cannot find 'SSHHostParser' in scope").

- [ ] **Step 3: Create the parser.**

Create `Mistty/Support/SSHHostParser.swift`:

```swift
import Foundation

/// Parses an SSH command string into the displayable host token.
///
/// Strategy: take the last token of the command that is NOT a flag
/// and is NOT the argument of a recognized ssh flag that takes a value
/// (`-p`, `-o`, `-i`, `-l`, `-F`, `-J`, `-b`, `-c`, `-D`, `-e`, `-E`,
/// `-I`, `-L`, `-m`, `-O`, `-Q`, `-R`, `-S`, `-w`). Split the token on
/// `@` and return the portion after it; if there's no `@`, return the
/// whole token.
enum SSHHostParser {
  private static let flagsTakingValue: Set<String> = [
    "-p", "-o", "-i", "-l", "-F", "-J", "-b", "-c", "-D",
    "-e", "-E", "-I", "-L", "-m", "-O", "-Q", "-R", "-S", "-w",
  ]

  static func host(from command: String) -> String? {
    let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard tokens.count >= 2 else { return nil }

    var i = 1  // skip the ssh binary itself
    var hostToken: String?
    while i < tokens.count {
      let tok = tokens[i]
      if flagsTakingValue.contains(tok) {
        i += 2  // skip flag and its value
        continue
      }
      if tok.hasPrefix("-") {
        i += 1
        continue
      }
      hostToken = tok
      i += 1
    }

    guard let raw = hostToken else { return nil }
    if let atIdx = raw.firstIndex(of: "@") {
      return String(raw[raw.index(after: atIdx)...])
    }
    return raw
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `swift test --filter MisttyTests.SSHHostParserTests`
Expected: all 7 tests PASS.

- [ ] **Step 5: Commit.**

```bash
git add Mistty/Support/SSHHostParser.swift MisttyTests/Support/SSHHostParserTests.swift
git commit -m "$(cat <<'EOF'
feat(ssh): add SSHHostParser for extracting host from command string

Skips ssh flags (including value-taking flags like -p, -i); returns
the post-@ portion when a user@host form is present.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.2: Add `customName` field to `MisttySession` and `SessionStore.createSession`

**Files:**
- Modify: `Mistty/Models/MisttySession.swift`
- Modify: `Mistty/Models/SessionStore.swift`

- [ ] **Step 1: Add `customName` stored property.**

In `Mistty/Models/MisttySession.swift`, add a `customName` property after the existing `name` property. Modify the top of the class:

```swift
@Observable
@MainActor
final class MisttySession: Identifiable {
  let id: Int
  var name: String
  var customName: String?
  let directory: URL
  var sshCommand: String?
```

And extend the initializer to accept it:

```swift
init(
  id: Int, name: String, directory: URL, exec: String? = nil,
  customName: String? = nil,
  tabIDGenerator: @escaping () -> Int,
  paneIDGenerator: @escaping () -> Int, popupIDGenerator: @escaping () -> Int
) {
  self.id = id
  self.name = name
  self.customName = customName
  self.directory = directory
  self.tabIDGenerator = tabIDGenerator
  self.paneIDGenerator = paneIDGenerator
  self.popupIDGenerator = popupIDGenerator
  addTab(exec: exec)
}
```

- [ ] **Step 2: Thread `customName` through `SessionStore.createSession`.**

In `Mistty/Models/SessionStore.swift`, replace the entire `createSession` function with:

```swift
@discardableResult
func createSession(
  name: String, directory: URL, exec: String? = nil, customName: String? = nil
) -> MisttySession {
  let session = MisttySession(
    id: generateSessionID(),
    name: name,
    directory: directory,
    exec: exec,
    customName: customName,
    tabIDGenerator: { [weak self] in
      guard let self else {
        assertionFailure("SessionStore was deallocated while sessions still exist")
        return 0
      }
      return self.generateTabID()
    },
    paneIDGenerator: { [weak self] in
      guard let self else {
        assertionFailure("SessionStore was deallocated while sessions still exist")
        return 0
      }
      return self.generatePaneID()
    },
    popupIDGenerator: { [weak self] in
      guard let self else {
        assertionFailure("SessionStore was deallocated while sessions still exist")
        return 0
      }
      return self.generatePopupID()
    }
  )
  sessions.append(session)
  activeSession = session
  return session
}
```

Changes vs existing: new `customName: String? = nil` trailing parameter, passed through to the `MisttySession(...)` call.

- [ ] **Step 3: Build.**

Run: `swift build`
Expected: clean build. All existing call sites still compile because `customName` has a default of `nil`.

- [ ] **Step 4: Commit.**

```bash
git add Mistty/Models/MisttySession.swift Mistty/Models/SessionStore.swift
git commit -m "$(cat <<'EOF'
feat(session): add customName field to MisttySession

Optional, defaulted, threaded through SessionStore.createSession.
Unused until the sidebar label computed property reads it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.3: Test + implement `MisttySession.sidebarLabel`

**Files:**
- Modify: `Mistty/Models/MisttySession.swift`
- Create: `MisttyTests/Models/MisttySessionSidebarLabelTests.swift`

- [ ] **Step 1: Write the failing tests.**

Create `MisttyTests/Models/MisttySessionSidebarLabelTests.swift`:

```swift
import XCTest

@testable import Mistty

@MainActor
final class MisttySessionSidebarLabelTests: XCTestCase {

  private func makeSession(
    name: String = "test",
    customName: String? = nil,
    directory: URL = URL(fileURLWithPath: "/Users/me/Developer/proj"),
    sshCommand: String? = nil
  ) -> MisttySession {
    let store = SessionStore()
    let s = store.createSession(
      name: name, directory: directory, customName: customName)
    s.sshCommand = sshCommand
    return s
  }

  func test_customNameWins() {
    let s = makeSession(customName: "my-project")
    XCTAssertEqual(s.sidebarLabel, "my-project")
  }

  func test_sshHostOverridesCWD() {
    let s = makeSession(sshCommand: "ssh manu@dev.example.com")
    XCTAssertEqual(s.sidebarLabel, "dev.example.com")
  }

  func test_customNameBeatsSSHHost() {
    let s = makeSession(
      customName: "staging",
      sshCommand: "ssh manu@dev.example.com"
    )
    XCTAssertEqual(s.sidebarLabel, "staging")
  }

  func test_activePaneCWDBasename() {
    let dir = URL(fileURLWithPath: "/Users/me/Developer/proj")
    let s = makeSession(directory: dir)
    // No customName, no SSH — falls through to active pane's directory basename.
    XCTAssertEqual(s.sidebarLabel, "proj")
  }

  func test_fallsBackToSessionDirectoryBasename() {
    // Construct a session whose activeTab's activePane lacks a directory —
    // this exercises the fallback chain all the way to `directory.lastPathComponent`.
    let dir = URL(fileURLWithPath: "/Users/me/other")
    let s = makeSession(directory: dir)
    s.activeTab?.activePane?.directory = nil
    XCTAssertEqual(s.sidebarLabel, "other")
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `swift test --filter MisttyTests.MisttySessionSidebarLabelTests`
Expected: FAIL with compilation error ("value of type 'MisttySession' has no member 'sidebarLabel'").

- [ ] **Step 3: Add `sidebarLabel` to `MisttySession`.**

In `Mistty/Models/MisttySession.swift`, add this computed property at the end of the class, just before the closing brace:

```swift
var sidebarLabel: String {
  if let customName, !customName.isEmpty {
    return customName
  }
  if let sshCommand, let host = SSHHostParser.host(from: sshCommand), !host.isEmpty {
    return host
  }
  if let cwd = activeTab?.activePane?.directory {
    return cwd.lastPathComponent
  }
  return directory.lastPathComponent
}
```

- [ ] **Step 4: Run the tests.**

Run: `swift test --filter MisttyTests.MisttySessionSidebarLabelTests`
Expected: all 5 tests PASS.

- [ ] **Step 5: Commit.**

```bash
git add Mistty/Models/MisttySession.swift MisttyTests/Models/MisttySessionSidebarLabelTests.swift
git commit -m "$(cat <<'EOF'
feat(session): add sidebarLabel with priority chain

customName -> SSH host -> active pane CWD basename -> session dir basename.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.4: Populate `customName` on plain-text session creation

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift`

**Context:** When the user types a non-path, non-SSH query in the session manager and hits Enter, we record that query as the `customName`. Other creation paths (running session reuse, directory row, SSH host row, directory create, path-like query) do not set `customName` — the sidebar falls through to the other branches of the priority chain.

- [ ] **Step 1: Wire `customName` through `confirmSelection`.**

In `Mistty/Views/SessionManager/SessionManagerViewModel.swift`, inside `confirmSelection`, locate the `.newSession` branch's plain-text fork (the `else` branch inside `if let sshCommand { ... } else { ... }`). Modify it:

```swift
} else {
  // Create directory if needed (use withIntermediateDirectories: true
  // to handle race condition where directory was created between filter and confirm)
  if createDir {
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  let isPathLike = query.contains("/") || query.hasPrefix("~")
  let name = isPathLike ? directory.lastPathComponent : query
  // When the user typed a plain-text name (not a path, not SSH),
  // record it as customName so the sidebar shows it verbatim even if
  // the active pane's CWD changes later.
  let customName: String? = isPathLike ? nil : query
  store.createSession(name: name, directory: directory, customName: customName)
}
```

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Run existing session manager tests to confirm no regressions.**

Run: `swift test --filter MisttyTests.SessionManagerViewModelTests`
Expected: all existing tests still pass.

- [ ] **Step 4: Commit.**

```bash
git add Mistty/Views/SessionManager/SessionManagerViewModel.swift
git commit -m "$(cat <<'EOF'
feat(session-manager): set customName when query is a plain-text name

Path-like and SSH queries leave customName nil so the sidebar label
falls through to SSH host or CWD basename.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.5: Render `sidebarLabel` in `SidebarView`

**Files:**
- Modify: `Mistty/Views/Sidebar/SidebarView.swift`

- [ ] **Step 1: Swap `session.name` for `session.sidebarLabel` in the session row label.**

In `Mistty/Views/Sidebar/SidebarView.swift`, inside `SessionRowView.body`'s `DisclosureGroup { ... } label: { ... }`, replace:

```swift
} label: {
  Text(session.name)
    .fontWeight(isActive ? .semibold : .regular)
    .contentShape(Rectangle())
    .onTapGesture { store.activeSession = session }
}
```

with:

```swift
} label: {
  Text(session.sidebarLabel)
    .fontWeight(isActive ? .semibold : .regular)
    .contentShape(Rectangle())
    .onTapGesture { store.activeSession = session }
}
```

Only the text source changed.

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Manually verify.**

Launch. Test each priority branch:
1. Create a session from the "New session" row with a typed name (e.g. "foo") → sidebar shows "foo". ✅
2. Create via SSH host row → sidebar shows host. Confirm that after `cd` inside the SSH pane, the sidebar label stays pinned to the host (customName fallthrough happens only when customName is nil). ✅
3. Create via directory row → sidebar shows the directory's basename (no customName, not SSH, falls through to active pane CWD). Change dir in the pane → sidebar label follows the new CWD. ✅

- [ ] **Step 4: Commit.**

```bash
git add Mistty/Views/Sidebar/SidebarView.swift
git commit -m "$(cat <<'EOF'
feat(sidebar): use sidebarLabel for session row text

Shows custom name, SSH host, or active-pane CWD basename depending on
which field is set, instead of the static session name.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Phase 5 — Process icons via bundled Nerd Font

### Task 5.1: Bundle the Nerd Font symbols file

**Files:**
- Create: `Mistty/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf`
- Modify: `Package.swift`

- [ ] **Step 1: Ensure the fonts directory exists.**

Run: `ls Mistty/Resources/`
Expected: existing directory (contains `Info.plist` at minimum).

Run: `mkdir -p Mistty/Resources/Fonts`

- [ ] **Step 2: Download the Symbols-only Nerd Font release.**

Run:
```bash
curl -L -o /tmp/NerdFontsSymbolsOnly.zip \
  https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/NerdFontsSymbolsOnly.zip
unzip -o /tmp/NerdFontsSymbolsOnly.zip -d /tmp/NerdFontsSymbolsOnly
ls /tmp/NerdFontsSymbolsOnly/
```

Expected: files including `SymbolsNerdFontMono-Regular.ttf`. If the filename differs between releases, use the closest `Mono-Regular.ttf` variant.

- [ ] **Step 3: Copy the TTF into the project.**

Run:
```bash
cp /tmp/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf \
   Mistty/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf
```

Verify: `ls Mistty/Resources/Fonts/` shows the TTF.

- [ ] **Step 4: Register the font as an SPM resource.**

In `Package.swift`, modify the Mistty executableTarget to add a `resources:` entry. Replace:

```swift
.executableTarget(
    name: "Mistty",
    dependencies: [
        "GhosttyKit",
        "MisttyShared",
        .product(name: "TOMLKit", package: "TOMLKit"),
    ],
    path: "Mistty",
    exclude: ["Resources/Info.plist"],
    linkerSettings: [
```

with:

```swift
.executableTarget(
    name: "Mistty",
    dependencies: [
        "GhosttyKit",
        "MisttyShared",
        .product(name: "TOMLKit", package: "TOMLKit"),
    ],
    path: "Mistty",
    exclude: ["Resources/Info.plist"],
    resources: [
        .process("Resources/Fonts"),
    ],
    linkerSettings: [
```

- [ ] **Step 5: Build.**

Run: `swift build`
Expected: clean build. The font is now copied into the app's resource bundle.

- [ ] **Step 6: Commit.**

```bash
git add Mistty/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf Package.swift
git commit -m "$(cat <<'EOF'
feat(ui): bundle Symbols-Only Nerd Font (v3.2.1, Mono Regular)

~200KB font providing ~10k icon glyphs for UI chrome; registered as
an SPM process resource. Not used for the terminal surface itself.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.2: Register the font at app launch

**Files:**
- Modify: `Mistty/App/MisttyApp.swift`

- [ ] **Step 1: Add a font-registration helper and call it from `init`.**

In `Mistty/App/MisttyApp.swift`, add `import CoreText` at the top if not already present. Then modify the `init()`:

```swift
init() {
  _ = GhosttyAppManager.shared
  Self.registerBundledFonts()
}

private static func registerBundledFonts() {
  guard let url = Bundle.module.url(
    forResource: "SymbolsNerdFontMono-Regular",
    withExtension: "ttf")
  else {
    assertionFailure("SymbolsNerdFontMono-Regular.ttf missing from bundle")
    return
  }
  var error: Unmanaged<CFError>?
  if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
    let err = error?.takeRetainedValue()
    assertionFailure("Failed to register bundled Nerd Font: \(String(describing: err))")
  }
}
```

Note: SPM resources are accessed via `Bundle.module` (which is auto-generated by SPM for targets with a `resources:` entry).

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Smoke-verify the font loads at launch.**

Launch the app and, from Xcode's console or a print statement added temporarily to `init()`, confirm no assertion failures fire. (Remove any debug prints before committing.)

- [ ] **Step 4: Commit.**

```bash
git add Mistty/App/MisttyApp.swift
git commit -m "$(cat <<'EOF'
feat(ui): register bundled Nerd Font at app launch

Process-scoped registration via CTFontManagerRegisterFontsForURL so
the glyphs are available to SwiftUI views without leaking into the
system-wide font list.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.3: Test + implement `ProcessIcon`

**Files:**
- Create: `Mistty/Support/ProcessIcon.swift`
- Create: `MisttyTests/Support/ProcessIconTests.swift`

- [ ] **Step 1: Write the failing tests.**

Create `MisttyTests/Support/ProcessIconTests.swift`:

```swift
import XCTest

@testable import Mistty

final class ProcessIconTests: XCTestCase {
  func test_nilInputReturnsFallback() {
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: nil), ProcessIcon.fallbackGlyph)
  }

  func test_emptyStringReturnsFallback() {
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: ""), ProcessIcon.fallbackGlyph)
  }

  func test_knownProcess_nvim() {
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: "nvim"), ProcessIcon.nvimGlyph)
  }

  func test_knownProcessWithArgs() {
    // "nvim PLAN.md" -> normalize to "nvim"
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: "nvim PLAN.md"), ProcessIcon.nvimGlyph)
  }

  func test_knownProcessCaseInsensitive() {
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: "NVIM"), ProcessIcon.nvimGlyph)
  }

  func test_unknownProcessReturnsFallback() {
    XCTAssertEqual(
      ProcessIcon.glyph(forProcessTitle: "some-unknown-binary"),
      ProcessIcon.fallbackGlyph)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `swift test --filter MisttyTests.ProcessIconTests`
Expected: FAIL with "cannot find 'ProcessIcon' in scope".

- [ ] **Step 3: Create `ProcessIcon.swift`.**

Create `Mistty/Support/ProcessIcon.swift`:

```swift
import Foundation

/// Maps process titles to Nerd Font glyphs for sidebar display.
///
/// Glyph codepoints source: Nerd Fonts v3 cheat sheet.
/// https://www.nerdfonts.com/cheat-sheet
enum ProcessIcon {
  static let fontName = "SymbolsNerdFontMono"

  static let fallbackGlyph: Character = "\u{f489}"    // nf-dev-terminal
  static let sshGlyph: Character = "\u{f0c2e}"        // nf-md-ssh
  static let nvimGlyph: Character = "\u{e7c5}"        // nf-dev-vim

  private static let map: [String: Character] = [
    "nvim": nvimGlyph, "vim": nvimGlyph, "neovim": nvimGlyph,
    "claude": "\u{f0335}",        // nf-md-creation
    "zsh": "\u{f489}", "bash": "\u{f489}", "fish": "\u{f489}", "sh": "\u{f489}",
    "node": "\u{e718}", "npm": "\u{e71e}", "pnpm": "\u{e718}", "yarn": "\u{e6a7}",
    "python": "\u{e73c}", "python3": "\u{e73c}", "ipython": "\u{e73c}",
    "ruby": "\u{e739}", "irb": "\u{e739}",
    "go": "\u{e627}",
    "cargo": "\u{e7a8}", "rustc": "\u{e7a8}",
    "docker": "\u{f308}",
    "git": "\u{f1d3}", "lazygit": "\u{f1d3}",
    "ssh": sshGlyph, "mosh": sshGlyph,
    "tmux": "\u{ebc8}",
    "htop": "\u{f2db}", "btop": "\u{f2db}",
    "mysql": "\u{e704}", "psql": "\u{e76e}",
    "make": "\u{e673}",
  ]

  static func glyph(forProcessTitle title: String?) -> Character {
    guard let normalized = normalize(title) else { return fallbackGlyph }
    return map[normalized] ?? fallbackGlyph
  }

  private static func normalize(_ title: String?) -> String? {
    guard let title = title?.lowercased() else { return nil }
    let firstToken = title.split(separator: " ").first.map(String.init) ?? title
    return firstToken.isEmpty ? nil : firstToken
  }
}
```

- [ ] **Step 4: Run the tests.**

Run: `swift test --filter MisttyTests.ProcessIconTests`
Expected: all 6 tests PASS.

- [ ] **Step 5: Commit.**

```bash
git add Mistty/Support/ProcessIcon.swift MisttyTests/Support/ProcessIconTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): add ProcessIcon mapping for Nerd Font glyphs

~30-entry static dictionary covering common shells, editors, language
runtimes, VCS, container, and infra tools. Fallback is the generic
terminal glyph.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.4: Add a session-level icon helper

**Files:**
- Modify: `Mistty/Support/ProcessIcon.swift`

- [ ] **Step 1: Add a session-aware glyph function.**

At the end of the `ProcessIcon` enum in `Mistty/Support/ProcessIcon.swift`, add:

```swift
@MainActor
static func glyph(forSession session: MisttySession) -> Character {
  if session.sshCommand != nil { return sshGlyph }
  return glyph(forProcessTitle: session.activeTab?.activePane?.processTitle)
}
```

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit.**

```bash
git add Mistty/Support/ProcessIcon.swift
git commit -m "$(cat <<'EOF'
feat(ui): add session-level glyph helper on ProcessIcon

SSH sessions get the network glyph regardless of pane process;
non-SSH sessions reflect the active pane's process title.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.5: Render icons in `SidebarView`

**Files:**
- Modify: `Mistty/Views/Sidebar/SidebarView.swift`

- [ ] **Step 1: Add a session-level icon in the disclosure group label.**

In `Mistty/Views/Sidebar/SidebarView.swift`, replace the `label: { ... }` of the `DisclosureGroup`:

```swift
} label: {
  HStack(spacing: 6) {
    Text(String(ProcessIcon.glyph(forSession: session)))
      .font(.custom(ProcessIcon.fontName, size: 12))
      .foregroundStyle(.secondary)
      .frame(width: 14, alignment: .center)
    Text(session.sidebarLabel)
      .fontWeight(isActive ? .semibold : .regular)
    Spacer()
  }
  .contentShape(Rectangle())
  .onTapGesture { store.activeSession = session }
}
```

- [ ] **Step 2: Add a per-tab icon in the tab row.**

In the same file, inside `SessionRowView.body`'s `ForEach(session.tabs) { tab in HStack { ... } }`, modify the `HStack` to include the icon:

```swift
ForEach(session.tabs) { tab in
  HStack {
    Text(String(ProcessIcon.glyph(forProcessTitle: tab.activePane?.processTitle)))
      .font(.custom(ProcessIcon.fontName, size: 12))
      .foregroundStyle(.secondary)
      .frame(width: 14, alignment: .center)
    if tab.hasBell {
      Circle()
        .fill(Color.orange)
        .frame(width: 6, height: 6)
    }
    Text(tab.displayTitle)
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
```

The icon leads the row; the bell dot (if any) follows; then the title.

- [ ] **Step 3: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Manually verify.**

Launch. Check:
- Session rows show a glyph appropriate to the session's active pane (e.g. `nvim` → vim glyph, `zsh` → terminal glyph).
- SSH sessions show the network glyph at the session level.
- Tab rows show their own pane's glyph — may differ from the session-level one.
- Glyphs render cleanly (no missing-glyph box). If they don't, the font isn't being located — re-verify Task 5.1 and 5.2.

- [ ] **Step 5: Commit.**

```bash
git add Mistty/Views/Sidebar/SidebarView.swift
git commit -m "$(cat <<'EOF'
feat(sidebar): render process icons on session and tab rows

Sidebar rows lead with a 12pt Nerd Font glyph reflecting the process
running in the active pane (session row) or the pane directly (tab row).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Phase 6 — Session manager SFSymbols

### Task 6.1: Add `symbolName` to `SessionManagerItem` and strip Unicode prefixes

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift`

- [ ] **Step 1: Add `symbolName` computed property.**

In `Mistty/Views/SessionManager/SessionManagerViewModel.swift`, inside the `SessionManagerItem` enum, add (after the existing `frecencyKey` computed property):

```swift
var symbolName: String {
  switch self {
  case .runningSession: return "terminal.fill"
  case .directory: return "folder"
  case .sshHost: return "network"
  case .newSession: return "plus.circle"
  }
}
```

- [ ] **Step 2: Drop the Unicode prefixes from `displayName`.**

Replace the `displayName` computed property:

```swift
var displayName: String {
  switch self {
  case .runningSession(let s): return s.name
  case .directory(let u): return u.lastPathComponent
  case .sshHost(let h): return h.alias
  case .newSession(let query, let directory, let createDir, let sshCommand):
    if sshCommand != nil {
      let hostname = query.drop(while: { $0 != " " }).dropFirst().trimmingCharacters(
        in: .whitespaces)
      return "New SSH session: \(hostname)"
    } else if createDir {
      return "New session + create directory: \(directory.path)"
    } else {
      let name =
        query.contains("/") || query.hasPrefix("~")
        ? directory.lastPathComponent : query
      return "New session: \(name)"
    }
  }
}
```

Changed: dropped `"▶ "` prefix on `.runningSession` and `"⌁ "` on `.sshHost`.

- [ ] **Step 3: Update `matchableFields` prefix lengths.**

In the same file, replace `matchableFields`:

```swift
private func matchableFields(for item: SessionManagerItem) -> (
  rawName: String, subtitle: String?, prefixLen: Int
) {
  switch item {
  case .runningSession(let s):
    return (s.name, nil, 0)
  case .directory(let u):
    return (u.lastPathComponent, u.path, 0)
  case .sshHost(let h):
    return (h.alias, h.hostname, 0)
  case .newSession:
    return ("", nil, 0)
  }
}
```

Changed: `prefixLen` is now `0` for all cases (no Unicode prefix means highlight indices already align with `displayName`).

- [ ] **Step 4: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 5: Commit.**

```bash
git add Mistty/Views/SessionManager/SessionManagerViewModel.swift
git commit -m "$(cat <<'EOF'
refactor(session-manager): add symbolName, drop Unicode display prefixes

Unicode arrow/lightning prefixes were a text hack for row-type cues;
they're replaced by an SFSymbol column in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6.2: Render the SFSymbol icon column in the view

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerView.swift`

- [ ] **Step 1: Add the icon column to each row.**

In `Mistty/Views/SessionManager/SessionManagerView.swift`, locate the `ForEach(Array(vm.filteredItems.enumerated()), id: \.element.id)` inside the `LazyVStack`. The row is an `HStack { VStack(...) Spacer() }`. Wrap with an icon `Image`. Replace:

```swift
ForEach(Array(vm.filteredItems.enumerated()), id: \.element.id) { index, item in
  HStack {
    VStack(alignment: .leading, spacing: 2) {
      if case .newSession = item {
        HStack(spacing: 4) {
          Image(systemName: "plus.circle")
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
          Text(item.displayName)
            .font(.system(size: 13))
            .lineLimit(1)
        }
      } else {
        let matchResult = vm.matchResults[item.id]
        HighlightedText(
          text: item.displayName,
          indices: Set(matchResult?.displayNameIndices ?? [])
        )
        .font(.system(size: 13))
        .lineLimit(1)
      }
      if let subtitle = item.subtitle {
        let matchResult = vm.matchResults[item.id]
        HighlightedText(
          text: subtitle,
          indices: Set(matchResult?.subtitleIndices ?? [])
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
    }
    Spacer()
  }
```

with:

```swift
ForEach(Array(vm.filteredItems.enumerated()), id: \.element.id) { index, item in
  HStack(spacing: 8) {
    Image(systemName: item.symbolName)
      .font(.system(size: 13))
      .frame(width: 16, height: 16)
      .foregroundStyle(index == vm.selectedIndex ? Color.accentColor : .secondary)
    VStack(alignment: .leading, spacing: 2) {
      let matchResult = vm.matchResults[item.id]
      HighlightedText(
        text: item.displayName,
        indices: Set(matchResult?.displayNameIndices ?? [])
      )
      .font(.system(size: 13))
      .lineLimit(1)
      if let subtitle = item.subtitle {
        HighlightedText(
          text: subtitle,
          indices: Set(matchResult?.subtitleIndices ?? [])
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
    }
    Spacer()
  }
```

The special-case block for `.newSession` that rendered a small `plus.circle` inside the text column is gone — the outer `Image` handles all row types uniformly (using `symbolName`).

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Manually verify.**

Open the app, press ⌘J to open the session manager. Verify:
- Running sessions show `terminal.fill` icon.
- Recent directories show `folder`.
- SSH hosts show `network`.
- "New session" row shows `plus.circle`.
- Selected row's icon is tinted accent color.
- No Unicode prefixes in titles.

- [ ] **Step 4: Commit.**

```bash
git add Mistty/Views/SessionManager/SessionManagerView.swift
git commit -m "$(cat <<'EOF'
feat(session-manager): SFSymbol icon column per row

Runs on item.symbolName: terminal.fill, folder, network, plus.circle.
Selected row's icon tinted with the accent color; others are
.secondary-styled.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6.3: Update session manager tests for dropped prefixes

**Files:**
- Modify: `MisttyTests/Views/SessionManagerViewModelTests.swift`

- [ ] **Step 1: Audit tests against new `displayName` values.**

Read `MisttyTests/Views/SessionManagerViewModelTests.swift` in full. Any test that asserted against the exact `displayName` of `.runningSession` or `.sshHost` (e.g. expecting `"▶ foo"` or `"⌁ host"`) must drop the prefix from its expected value.

As of the last audit:
- `test_newSessionItem_plainText_properties` expects `"New session: proj"` — unchanged.
- `test_newSessionItem_createDirectory_properties` expects a substring — unchanged.
- No other tests currently assert on `displayName` text for prefixed row types.

However, any new assertions that might have been added between when this plan was written and implementation time should be re-checked with the command below.

- [ ] **Step 2: Run all tests to catch any breakage.**

Run: `swift test`
Expected: all tests PASS.

If a test fails due to an expected value containing `"▶ "` or `"⌁ "`, update the expected value to drop the prefix, then re-run.

- [ ] **Step 3: Commit (only if changes were needed).**

If tests were edited:

```bash
git add MisttyTests/Views/SessionManagerViewModelTests.swift
git commit -m "$(cat <<'EOF'
test(session-manager): update expectations after dropping Unicode prefixes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If no test edits were needed, skip this commit.

---

## Final verification

### Task F.1: Full test run + manual smoke

- [ ] **Step 1: Run the full test suite.**

Run: `swift test`
Expected: all tests PASS (including Phase 4 sidebar label tests, Phase 5 ProcessIcon tests, Phase 4 SSH parser tests, and all pre-existing tests).

- [ ] **Step 2: Launch and exercise each touched surface.**

Launch the app. Verify in sequence:
1. Traffic lights visible, no title bar, window draggable from top strip.
2. Toggle sidebar (⌘S) — slides in/out over ~180ms.
3. Open session manager (⌘J) — SFSymbols visible next to each row; selected row icon is tinted.
4. Create a session with a plain-text name — sidebar shows that name.
5. Create a session via a recent directory — sidebar shows directory basename; runs `cd` in the pane and the sidebar label follows.
6. Create an SSH session — sidebar shows the host.
7. Single tab — no tab bar. Add a second tab (⌘T) — tab bar slides down. Close second tab — tab bar slides up.
8. Sidebar rows show process icons; tab rows show process icons.

- [ ] **Step 3: If everything passes, the feature is complete.**

No commit needed for this verification task.

---

## Rollback notes

Each phase commits independently, so a bad phase can be reverted without affecting later ones — but later phases have dependencies on earlier ones:
- Phase 2 depends on Phase 1 (insets rely on title bar being hidden).
- Phase 5 depends on Phase 4 (`ProcessIcon.glyph(forSession:)` assumes `activePane` structure is unchanged — which it is).
- Phases 3 and 6 are independent of each other and of 4/5.

A revert of Phase 4 requires also reverting Phase 5's `glyph(forSession:)` and the sidebar's use of `sidebarLabel`.
