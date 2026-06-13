# Audit Fixes Wave 3: Mechanical Dedups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the five biggest copy-paste families found by the 2026-06 audit: the 32-subcommand CLI scaffold (~600 redundant lines), the 27-method IPCService scaffold (~250), the hand-written menu buttons (~190), the duplicated socket I/O/framing, and the duplicated snapshot/restore logic in WindowsStore — plus centralize all `ghostty_selection_s` text reading in one `TerminalSurfaceView` API and flatten the `withCString` pyramid.

**Architecture:** Pure refactors — wire formats, CLI output, and user-visible behavior stay identical, with two deliberate, named improvements: (a) `reopenMostRecentClosed` now honors the snapshot's `activeTabID` (it previously always activated the first tab), and (b) the Close Window menu item gains the same debug-log line its Close Pane/Tab siblings already had. Tasks 1 and 2 define a helper plus fully-worked example conversions, then enumerate every remaining call site in a table — the transformation is mechanical and the existing test suites (`IPCServiceTests` et al.) are the safety net.

**Tech Stack:** Swift / SwiftPM, XCTest. Verification commands:
- Full suite: `swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log` — the 23 `ChromePolishSnapshotTests` failures are the known pre-existing baseline; anything else is a regression.
- Build: `swift build 2>&1 | tee /tmp/mistty-build.log`

---

### Task 1: CLI `IPCRun` helper — collapse the 32-subcommand scaffold

**Files:**
- Create: `MisttyCLI/IPCRun.swift`
- Modify: `MisttyCLI/Commands/PaneCommand.swift`, `TabCommand.swift`, `SessionCommand.swift`, `WindowCommand.swift`, `PopupCommand.swift`, `ConfigCommand.swift`, `DebugCommand.swift`, `VersionCommand.swift`

There are no CLI unit tests; verification is build + `git diff --stat` shrinkage + the unchanged-behavior rules below.

**Behavior-preservation rules:**
1. Decode errors must still PROPAGATE (today they escape `func run() throws` and ArgumentParser reports them) — that's why `single`/`list` are `throws` and do NOT catch decode errors.
2. IPC/connection errors must still print `Error: <localizedDescription>` to stderr and `exit(1)`.
3. Param-building logic (conditional params, validation) stays in each subcommand, untouched.

- [ ] **Step 1: Create the helper**

Create `MisttyCLI/IPCRun.swift`:

```swift
import Foundation
import MisttyShared

/// Shared execution scaffold for CLI subcommands. Every subcommand used to
/// repeat the same ritual: build formatter, ensure the app is reachable,
/// call, print-error-and-exit(1) on failure, decode, print. Decode errors
/// intentionally PROPAGATE (as before) so ArgumentParser reports them.
enum IPCRun {
    /// Reachability + call + print-error-and-exit. The shared trunk of all
    /// three entry points; also usable directly by subcommands with bespoke
    /// post-processing.
    static func call(
        _ method: String, _ params: [String: Any] = [:], formatter: OutputFormatter
    ) -> Data {
        let client = IPCClient()
        do {
            try client.ensureReachable()
            return try client.call(method, params)
        } catch {
            formatter.printError(error.localizedDescription)
            Foundation.exit(1)
        }
    }

    /// Call `method` and print the decoded single response.
    static func single<T: PrintableByFormatter & Codable>(
        _ method: String, _ params: [String: Any] = [:],
        format: OutputFormat, as type: T.Type, printHeader: Bool = true
    ) throws {
        let formatter = OutputFormatter(format: format)
        let data = call(method, params, formatter: formatter)
        let item = try JSONDecoder().decode(T.self, from: data)
        formatter.print(item, printHeader: printHeader)
    }

    /// Call `method` and print the decoded array response as a table.
    static func list<T: PrintableByFormatter & Codable>(
        _ method: String, _ params: [String: Any] = [:],
        format: OutputFormat, as type: T.Type
    ) throws {
        let formatter = OutputFormatter(format: format)
        let data = call(method, params, formatter: formatter)
        let items = try JSONDecoder().decode([T].self, from: data)
        formatter.print(items)
    }

    /// Call `method`, discard the payload, print a success message.
    static func fireAndForget(
        _ method: String, _ params: [String: Any] = [:],
        format: OutputFormat, success: String
    ) {
        let formatter = OutputFormatter(format: format)
        _ = call(method, params, formatter: formatter)
        formatter.printSuccess(success)
    }
}
```

- [ ] **Step 2: Convert PaneCommand — the fully-worked example**

The four shapes, worked on `MisttyCLI/Commands/PaneCommand.swift`:

`Create` (single, with param building — body of `run()` becomes):

```swift
        func run() throws {
            var params: [String: Any] = ["tabId": tab]
            if let direction { params["direction"] = direction }
            try IPCRun.single("createPane", params, format: format, as: PaneResponse.self)
        }
```

`List` (list):

```swift
        func run() throws {
            try IPCRun.list("listPanes", ["tabId": tab], format: format, as: PaneResponse.self)
        }
```

`Close` (fire-and-forget):

```swift
        func run() throws {
            IPCRun.fireAndForget("closePane", ["id": id], format: format,
                                 success: "Pane \(id) closed")
        }
```

`GetText` (single with `printHeader: false`):

```swift
        func run() throws {
            try IPCRun.single("getText", ["paneId": pane], format: format,
                              as: GetTextResponse.self, printHeader: false)
        }
```

`Focus` (bespoke branching — keep the branch, use the helper in each arm):

```swift
        func run() throws {
            if let direction {
                try IPCRun.single(
                    "focusPaneByDirection", ["direction": direction, "sessionId": session],
                    format: format, as: PaneResponse.self)
            } else if let id {
                try IPCRun.single("focusPane", ["id": id], format: format, as: PaneResponse.self)
            } else {
                // Should not reach here due to validate()
                OutputFormatter(format: format).printError("Provide either a pane ID or --direction")
                Foundation.exit(1)
            }
        }
```

Convert the remaining PaneCommand subcommands per the table below. Delete the now-unused `formatter`/`client`/`ensureReachable`/do-catch scaffolding from every converted body.

- [ ] **Step 3: Convert the remaining command files using this table**

| Subcommand | Helper | Method | Response / success |
|---|---|---|---|
| Pane.Get | single | getPane | PaneResponse |
| Pane.Resize | fireAndForget | resizePane | "Pane \(id) resized" |
| Pane.Active | single | activePane | PaneResponse |
| Pane.SendKeys | fireAndForget | sendKeys | "Keys sent" |
| Pane.RunCommand | fireAndForget | runCommand | "Command sent" |
| Tab.Create | single (param building stays) | createTab | TabResponse |
| Tab.List | list | listTabs | TabResponse |
| Tab.Get | single | getTab | TabResponse |
| Tab.Close | fireAndForget | closeTab | "Tab \(id) closed" |
| Tab.Rename | single | renameTab | TabResponse |
| Session.Create | single (param building stays) | createSession | SessionResponse |
| Session.List | list | listSessions | SessionResponse |
| Session.Get | single | getSession | SessionResponse |
| Session.Reparent | single | reparentSession | SessionResponse |
| Session.Close | fireAndForget | closeSession | "Session \(id) closed" |
| Window.Create | single | createWindow | WindowResponse |
| Window.List | list | listWindows | WindowResponse |
| Window.Get | single | getWindow | WindowResponse |
| Window.Close | fireAndForget | closeWindow | "Window \(id) closed" |
| Window.Focus | fireAndForget | focusWindow | "Window \(id) focused" |
| Popup.* / Config.* / Debug.* / Version.* | see rule below | | |

For PopupCommand, ConfigCommand, DebugCommand, VersionCommand: apply the same shapes where the body matches exactly; where a subcommand has bespoke post-processing (e.g. VersionCommand compares CLI/app versions, DebugCommand prints a raw snapshot, PopupCommand.Toggle calls then prints a custom success, PopupCommand uses listSessions for resolution), KEEP the bespoke logic and replace only the formatter/client/ensureReachable/do-catch scaffold with `IPCRun.call(_:_:formatter:)`. Never change what is printed.

- [ ] **Step 4: Verify**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log` — PASS.
Then confirm the scaffold is gone:
- `grep -rn "ensureReachable" MisttyCLI/Commands/` → 0 hits (all routed through IPCRun).
- `grep -rn "printError(error.localizedDescription)" MisttyCLI/Commands/` → 0 hits.
- `git diff --stat` should show MisttyCLI/Commands net shrinking by roughly 500+ lines.

- [ ] **Step 5: Commit**

```bash
git add MisttyCLI/
git commit -m "refactor(cli): collapse 32-subcommand scaffold into IPCRun helper

Every subcommand repeated the same formatter/ensureReachable/call/
print-error-exit/decode/print ritual (~35 lines each, 3 unique).
IPCRun.single/list/fireAndForget keep behavior identical: decode errors
still propagate to ArgumentParser, IPC errors still print and exit(1).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: IPCService — `onMain` + `require` dispatch helpers

**Files:**
- Modify: `Mistty/Services/IPCService.swift` (all 27 methods)

Safety net: `MisttyTests/Services/IPCServiceTests.swift` + `IPCServiceWindowResolutionTests.swift` exercise the dispatch surface — they must pass unchanged.

**Behavior-preservation rules:** identical error codes/messages, identical reply payloads. The three empty-success encodings (`encode([String: String]())`, `Data("{}".utf8)`) all produce the literal bytes `{}` — unifying on `Data("{}".utf8)` is wire-identical.

- [ ] **Step 1: Add the helpers**

In `Mistty/Services/IPCService.swift`, after the `encode` helper (line ~27), add:

```swift
  /// Shared dispatch scaffold. Wraps the reply for @MainActor capture,
  /// runs `body` on the main actor, encodes its return value (nil →
  /// empty `{}` success), and routes thrown errors to the reply's error
  /// slot. Every IPC method used to hand-roll this.
  private func onMain(
    _ reply: @escaping (Data?, Error?) -> Void,
    _ body: @escaping @MainActor () throws -> (any Encodable)?
  ) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      do {
        if let value = try body() {
          reply(self.encode(value), nil)
        } else {
          reply(Data("{}".utf8), nil)
        }
      } catch {
        reply(nil, error)
      }
    }
  }

  /// Unwrap an entity lookup or throw the matching IPC error.
  private func require<T>(
    _ value: T?, _ code: MisttyIPC.ErrorCode, _ message: String
  ) throws -> T {
    guard let value else { throw MisttyIPC.error(code, message) }
    return value
  }
```

(If `MisttyIPC.ErrorCode` is namespaced differently — check `MisttyShared/IPCConstants.swift` — match whatever type `MisttyIPC.error`'s first parameter takes.)

- [ ] **Step 2: Convert — fully-worked examples covering every shape**

Lookup + respond (`getTab`, currently lines 187-196):

```swift
  func getTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.tab(byId: id), .entityNotFound, "Tab \(id) not found")
      return self.tabResponse(resolved.tab, windowID: resolved.window.id)
    }
  }
```

Lookup + mutate + empty success (`closeTab`, lines 198-208):

```swift
  func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.tab(byId: id), .entityNotFound, "Tab \(id) not found")
      resolved.session.closeTab(resolved.tab)
      return nil
    }
  }
```

No lookup, list response (`listSessions`, lines 99-107):

```swift
  func listSessions(reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      self.windowsStore.windows.flatMap { window in
        window.sessions.map { self.sessionResponse($0, windowID: window.id) }
      }
    }
  }
```

Multi-step body with mid-body errors (`createTab`, lines 156-173) — each `guard ... reply(error); return` becomes `try self.require(...)` or a plain `throw`:

```swift
  func createTab(
    sessionId: Int, name: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void
  ) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.session(byId: sessionId), .entityNotFound,
        "Session \(sessionId) not found")
      resolved.session.addTab(exec: exec)
      let tab = try self.require(
        resolved.session.tabs.last, .operationFailed, "Failed to create tab")
      if let name { tab.customTitle = name }
      return self.tabResponse(tab, windowID: resolved.window.id)
    }
  }
```

- [ ] **Step 3: Convert all remaining methods**

Apply the same transformation to every method: `createSession`, `getSession`, `closeSession`, `reparentSession`, `listTabs`, `renameTab`, `createPane`, `listPanes`, `getPane`, `closePane`, `focusPane`, `focusPaneByDirection`, `resizePane`, `activePane`, `sendKeys`, `runCommand`, `getText`, `createWindow`, `listWindows`, `getWindow`, `closeWindow`, `focusWindow`, `openPopup`, `closePopup`, `togglePopup`, `listPopups`, `getVersion`, `reloadConfig`, `getStateSnapshot`. Preserve every error code and message string exactly (including the pane-id-0-means-active resolution in `sendKeys`/`runCommand`/`getText` — keep that logic inline in those bodies). Completion check: `grep -c "Reply(handler:" Mistty/Services/IPCService.swift` → exactly 1 (the one inside `onMain`); `grep -c "Task { @MainActor" Mistty/Services/IPCService.swift` → exactly 1.

- [ ] **Step 4: Verify**

Run: `swift test --skip Benchmark --filter "IPCService" 2>&1 | tee /tmp/mistty-test.log`
Expected: all IPCServiceTests + IPCServiceWindowResolutionTests PASS.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/IPCService.swift
git commit -m "refactor(ipc): collapse per-method dispatch scaffold into onMain/require

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Centralize terminal text reading on `TerminalSurfaceView`

**Files:**
- Modify: `Mistty/Views/Terminal/TerminalSurfaceView.swift` (add `readText`/`readRow`)
- Modify: `Mistty/App/ContentView.swift` (delete `readTerminalLine`/`readScreenLine`/`readGhosttyText` bodies, delegate)
- Modify: `Mistty/Views/Terminal/PaneView.swift` (lineReader closure)
- Modify: `Mistty/Services/IPCService.swift` (`getText`)

**Note:** same workstream as Task 2 (shared file IPCService.swift). Do Task 2 first, then this.

- [ ] **Step 1: Add the API to `TerminalSurfaceView`**

In `Mistty/Views/Terminal/TerminalSurfaceView.swift`, add (near the other `@MainActor` accessors like `shellPID`):

```swift
  /// Read a text range from the surface. The ONLY sanctioned way to read
  /// terminal text — builds the `ghostty_selection_s`, reads, and frees
  /// the C buffer in one place. Returns nil when the surface is gone or
  /// the read fails.
  @MainActor
  func readText(
    startRow: Int, startCol: Int, endRow: Int, endCol: Int,
    rectangle: Bool = false,
    pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT
  ) -> String? {
    guard let surface else { return nil }
    var sel = ghostty_selection_s()
    sel.top_left.tag = pointTag
    sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
    sel.top_left.x = UInt32(startCol)
    sel.top_left.y = UInt32(startRow)
    sel.bottom_right.tag = pointTag
    sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
    sel.bottom_right.x = UInt32(endCol)
    sel.bottom_right.y = UInt32(endRow)
    sel.rectangle = rectangle
    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let ptr = text.text else { return nil }
    return String(cString: ptr)
  }

  /// Read one full row (viewport row by default, screen row via pointTag).
  @MainActor
  func readRow(
    _ row: Int, pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT
  ) -> String? {
    guard let surface else { return nil }
    let cols = Int(ghostty_surface_size(surface).columns)
    guard cols > 0 else { return nil }
    return readText(
      startRow: row, startCol: 0, endRow: row, endCol: cols - 1, pointTag: pointTag)
  }
```

- [ ] **Step 2: Replace the duplicated builders**

1. `ContentView.readTerminalLine(row:)` body becomes:
```swift
  private func readTerminalLine(row: Int) -> String? {
    copyModePane?.surfaceView.readRow(row)
  }
```
2. `ContentView.readScreenLine(row:)` body becomes:
```swift
  private func readScreenLine(row: Int) -> String? {
    copyModePane?.surfaceView.readRow(row, pointTag: GHOSTTY_POINT_SCREEN)
  }
```
3. Delete `ContentView.readGhosttyText(surface:...)` entirely and convert its callers in `yankSelection` to `pane.surfaceView.readText(startRow:startCol:endRow:endCol:rectangle:pointTag:)` with identical arguments.
4. `PaneView`'s inline `reader` closure (lines 64-82) becomes:
```swift
            let reader: ((Int) -> String?)? = { row in
              pane.surfaceView.readRow(row)
            }
```
5. `IPCService.getText`: replace the inline selection build + read (the `var sel = ...` through the `content` extraction) with:
```swift
      let size = ghostty_surface_size(surface)
      let rows = Int(size.rows)
      let cols = Int(size.columns)
      let content = try self.require(
        pane.surfaceView.readText(
          startRow: 0, startCol: 0, endRow: rows - 1, endCol: cols - 1),
        .operationFailed, "Failed to read text from surface")
      return GetTextResponse(text: content)
```
(The `guard let surface = pane.surfaceView.surface` stays — it produces the distinct "Pane has no active surface" error first; only the read itself is delegated. Note `readText` returning nil now covers both read-failure and nil-text; the old code returned `""` for nil-text — to stay wire-faithful use `?? ""` ONLY if the existing tests assert it; default to the error mapping above and let IPCServiceTests arbitrate.)

- [ ] **Step 3: Verify**

Acceptance grep: `grep -rn "ghostty_selection_s" Mistty/ --include="*.swift"` → hits ONLY in `TerminalSurfaceView.swift`.
Run: `swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log` — only the 23 known snapshot failures.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Views/Terminal/TerminalSurfaceView.swift Mistty/Views/Terminal/PaneView.swift Mistty/App/ContentView.swift Mistty/Services/IPCService.swift
git commit -m "refactor(surface): single readText/readRow API for terminal text reads

The build-selection/read/free idiom was copy-pasted five times across
ContentView, PaneView, and IPCService. ghostty_selection_s is now
constructed only inside TerminalSurfaceView.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Flatten the `withCString` pyramid in surface creation

**Files:**
- Modify: `Mistty/Views/Terminal/TerminalSurfaceView.swift:160-205` (`createSurface`)

**Note:** same workstream as Tasks 2-3 (same file). Do after Task 3.

- [ ] **Step 1: Replace the 2³ branch pyramid**

In `Mistty/Views/Terminal/TerminalSurfaceView.swift`, add this private helper near `createSurface`:

```swift
    // Bridge an optional String to an optional C pointer that stays alive
    // for the duration of `body`. Collapses the 2^3 presence-combination
    // pyramid that previously enumerated every optional-field combination
    // with its own ghostty_surface_new call.
    func withOptionalCString(
      _ string: String?, _ body: (UnsafePointer<CChar>?) -> Void
    ) {
      if let string {
        string.withCString { body($0) }
      } else {
        body(nil)
      }
    }
```

and replace the entire body of the nested `createSurface(_:)` function (lines 160-205, the one with the `if let path = workingDirectoryPath { ... } else if let cmd ... }` pyramid) with:

```swift
    func createSurface(_ cfg: inout ghostty_surface_config_s) {
      withOptionalCString(workingDirectoryPath) { dirPtr in
        if dirPtr != nil { cfg.working_directory = dirPtr }
        withOptionalCString(commandString) { cmdPtr in
          if cmdPtr != nil { cfg.command = cmdPtr }
          withOptionalCString(initialInputString) { inputPtr in
            if inputPtr != nil { cfg.initial_input = inputPtr }
            surface = ghostty_surface_new(app, &cfg)
          }
        }
      }
    }
```

(Keep the existing comment above `createSurface` about pointer lifetimes; the fields are only assigned when non-nil, exactly as before.)

- [ ] **Step 2: Verify**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark --filter "MisttyPaneTests|MisttyTabTests|SessionCloseTeardownTests" 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS. (Surface creation is exercised end-to-end only by running the app; the structure guarantees the same pointers reach `ghostty_surface_new`.)

- [ ] **Step 3: Commit**

```bash
git add Mistty/Views/Terminal/TerminalSurfaceView.swift
git commit -m "refactor(surface): flatten withCString pyramid in createSurface

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Table-driven menu via `menuButton` helpers

**Files:**
- Modify: `Mistty/App/MisttyApp.swift:92-364` (menu commands) and the helper section near `kbShortcut` (line ~410)

- [ ] **Step 1: Add the helpers**

In `Mistty/App/MisttyApp.swift`, next to `kbShortcut` (line ~410), add:

```swift
  /// Standard menu item: title + post the action's notification, with the
  /// user-configured shortcut attached. Replaces 20+ hand-written
  /// Button/post/kbShortcut triples that re-encoded the action→notification
  /// mapping ShortcutAction.notificationName already owns.
  @ViewBuilder
  private func menuButton(_ action: ShortcutAction, _ title: String) -> some View {
    kbShortcut(
      action,
      on: Button(title) {
        NotificationCenter.default.post(name: action.notificationName, object: nil)
      }
    )
  }

  /// Close Pane/Tab/Window share a guard: when a non-terminal window
  /// (e.g. Settings) is key, let the system close that window instead of
  /// routing the shortcut to the terminal.
  @ViewBuilder
  private func closeMenuButton(_ action: ShortcutAction, _ title: String) -> some View {
    kbShortcut(
      action,
      on: Button(title) {
        if windowsStore.isTerminalWindowKey() {
          DebugLog.shared.log("cmdw", "menu \(title) → posting notification")
          NotificationCenter.default.post(name: action.notificationName, object: nil)
        } else {
          DebugLog.shared.log(
            "cmdw",
            "menu \(title) → performClose on keyWindow=\(NSApp.keyWindow.map { "num=\($0.windowNumber) title=\"\($0.title)\"" } ?? "nil")"
          )
          NSApp.keyWindow?.performClose(nil)
        }
      }
    )
  }
```

- [ ] **Step 2: Rewrite the CommandGroup body**

Replace each hand-written `kbShortcut(.x, on: Button("Title") { NotificationCenter...post(...) })` block with one line, preserving order and the `Divider()`s exactly:

```swift
      CommandGroup(after: .toolbar) {
        Divider()
        menuButton(.toggleSidebar, "Toggle Sidebar")
        menuButton(.toggleTabBar, "Toggle Tab Bar")
        menuButton(.reloadConfig, "Reload Config")
        menuButton(.newTab, "New Tab")
        menuButton(.newTabPlain, "New Tab (Plain)")
        menuButton(.splitHorizontal, "Split Pane Horizontally")
        menuButton(.splitHorizontalPlain, "Split Pane Horizontally (Plain)")
        menuButton(.splitVertical, "Split Pane Vertically")
        menuButton(.splitVerticalPlain, "Split Pane Vertically (Plain)")
        menuButton(.sessionManager, "Session Manager")
        Divider()
        closeMenuButton(.closePane, "Close Pane")
        closeMenuButton(.closeTab, "Close Tab")
        closeMenuButton(.closeWindow, "Close Window")
        menuButton(.reopenClosedWindow, "Reopen Closed Window")
        menuButton(.windowMode, "Window Mode")
        menuButton(.copyMode, "Copy Mode")
        menuButton(.yankHints, "Yank Hints (Copy)")
        menuButton(.yankHintsOpen, "Yank Hints (Open)")
        menuButton(.yankHintsCursor, "Yank Hints (Cursor)")
        Divider()
        menuButton(.renameTab, "Rename Tab")
        menuButton(.renameSession, "Rename Session")
        menuButton(.reparentSession, "Change Session Directory…")
        Divider()
        // (keep the two ForEach(1...9) index groups and the popup ForEach
        //  exactly as they are — they're parameterized, not action-table rows)
        ...
        menuButton(.nextTab, "Next Tab")
        menuButton(.prevTab, "Previous Tab")
        menuButton(.prevSession, "Previous Session")
        menuButton(.nextSession, "Next Session")
        menuButton(.swapSessionUp, "Move Session Up")
        menuButton(.swapSessionDown, "Move Session Down")
        Divider()
        // popup ForEach stays
        ...
      }
```

Keep the `ForEach(1...9)` focus-tab/focus-session groups and the popup `ForEach` untouched, in their current positions (between the Rename group's Divider and Next Tab, and after the final Divider, respectively — preserve the existing order exactly as in the current file).

Behavior notes (intentional, name them in the commit): `swapSessionUp/Down` post via `notificationName` which maps to `.misttyMoveSessionUp/Down` — same notification as the hand-written buttons posted, so no change; Close Window now logs the same `cmdw` debug line as its siblings (it previously logged only on the notification path).

- [ ] **Step 3: Verify**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log`
Expected: build PASS; only the 23 known snapshot failures. Sanity grep: `grep -c "menuButton(\|closeMenuButton(" Mistty/App/MisttyApp.swift` → 25.

- [ ] **Step 4: Commit**

```bash
git add Mistty/App/MisttyApp.swift
git commit -m "refactor(menu): table-driven menu items via ShortcutAction.notificationName

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Move socket I/O + framing into `MisttyShared/UnixSocket`

**Files:**
- Modify: `MisttyShared/UnixSocket.swift` (add readExact/writeAll/sendFrame/receiveFrame)
- Modify: `Mistty/Services/IPCListener.swift` (use them; delete local copies)
- Modify: `MisttyCLI/IPCClient.swift` (use them; delete local copies)

- [ ] **Step 1: Add the shared primitives**

Append to `MisttyShared/UnixSocket.swift` (inside the `UnixSocket` enum):

```swift
    /// Read exactly `count` bytes, looping on EINTR and short reads.
    /// Returns nil on error, EOF, or timeout.
    public static func readExact(fd: Int32, count: Int) -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress! + offset, count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            offset += n
        }
        return buffer
    }

    /// Write all bytes, looping on EINTR and short writes.
    @discardableResult
    public static func writeAll(fd: Int32, data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress! + offset, data.count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    /// Write a frame: 4-byte big-endian length prefix + payload.
    @discardableResult
    public static func sendFrame(fd: Int32, payload: Data) -> Bool {
        var length = UInt32(payload.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        return writeAll(fd: fd, data: lengthData) && writeAll(fd: fd, data: payload)
    }

    /// Read a frame: 4-byte big-endian length prefix + payload. Returns
    /// nil on I/O error or when the length is 0 or exceeds `maxSize`.
    public static func receiveFrame(fd: Int32, maxSize: Int) -> Data? {
        guard let lengthBytes = readExact(fd: fd, count: 4) else { return nil }
        let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, Int(length) <= maxSize else { return nil }
        return readExact(fd: fd, count: Int(length))
    }
```

- [ ] **Step 2: Use them in `IPCListener`**

In `Mistty/Services/IPCListener.swift`:
- `handleConnection`: replace the manual length-prefix read (lines reading `lengthBytes`/`length`/`requestData`) with:
```swift
    guard let requestData = UnixSocket.receiveFrame(fd: fd, maxSize: MisttyIPC.maxMessageSize)
    else { return }
```
- Replace `writeResponse(fd:data:)` calls with `UnixSocket.sendFrame(fd: fd, payload: data)` and DELETE the local `readExact`, `writeAll`, and `writeResponse` functions.

- [ ] **Step 3: Use them in `IPCClient`**

In `MisttyCLI/IPCClient.swift`, in `call(_:_:)`, replace the manual framing (the `var length...try writeAll...try readExact...responseLength` block) with:

```swift
        guard UnixSocket.sendFrame(fd: fd, payload: requestData) else {
            throw IPCClientError.connectionFailed("Write failed")
        }
        guard let responseData = UnixSocket.receiveFrame(
            fd: fd, maxSize: Int(MisttyIPC.maxMessageSize))
        else {
            throw IPCClientError.connectionFailed("Read failed")
        }
```

Keep the `!responseData.isEmpty` / status-byte / payload handling unchanged, and DELETE the local `readExact`/`writeAll`. (If `MisttyIPC.maxMessageSize` is already `Int`, drop the cast.)

- [ ] **Step 4: Verify**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark --filter "IPCService" 2>&1 | tee /tmp/mistty-test.log` — PASS.
Greps: `grep -rn "func readExact\|func writeAll" Mistty/ MisttyCLI/` → 0 hits (only MisttyShared).

- [ ] **Step 5: Commit**

```bash
git add MisttyShared/UnixSocket.swift Mistty/Services/IPCListener.swift MisttyCLI/IPCClient.swift
git commit -m "refactor(ipc): share socket I/O and framing via UnixSocket

readExact/writeAll and the 4-byte length-prefix framing were
implemented twice (app listener + CLI client).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Deduplicate WindowsStore snapshot/restore

**Files:**
- Modify: `Mistty/Models/WindowsStore+Snapshot.swift` (extract `snapshotWindow`, `restoreSessions`)
- Modify: `Mistty/Models/WindowsStore.swift` (`closeWindow`, `reopenMostRecentClosed` use them)
- Test: `MisttyTests/Snapshot/WindowsStoreSnapshotTests.swift`

**Known intentional behavior change:** `reopenMostRecentClosed` currently re-implements the restore loop and always sets `session.activeTab = session.tabs.first`, ignoring the snapshot's `activeTabID`; the shared helper honors `activeTabID` (tab IDs are preserved on reopen). This is a fix — pin it with the new test below.

- [ ] **Step 1: Write the failing test**

Add to `MisttyTests/Snapshot/WindowsStoreSnapshotTests.swift` (match the file's existing setup style for creating a store/window/session):

```swift
  /// reopenMostRecentClosed used to re-implement restore() inline and
  /// always activated the FIRST tab, losing which tab was active when the
  /// window closed. The shared restoreSessions helper honors activeTabID.
  func test_reopenMostRecentClosed_restoresActiveTab() {
    let store = WindowsStore()
    let window = store.createWindow()
    let session = window.createSession(
      name: "s", directory: URL(fileURLWithPath: "/tmp"))
    session.addTab()  // second tab
    let secondTabID = session.tabs[1].id
    session.activeTab = session.tabs[1]

    store.closeWindow(window)
    XCTAssertNotNil(store.reopenMostRecentClosed())

    let reopened = store.pendingRestoreStates.last
    let restoredSession = reopened?.sessions.first
    XCTAssertEqual(
      restoredSession?.activeTab?.id, secondTabID,
      "reopen must restore the tab that was active at close time")
  }
```

(If `pendingRestoreStates` is not accessible from tests, use whatever accessor the existing tests in this file use to reach restored state — they exercise the same path.)

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --skip Benchmark --filter WindowsStoreSnapshotTests 2>&1 | tee /tmp/mistty-test.log`
Expected: FAIL — restored activeTab is the first tab, not the second.

- [ ] **Step 3: Extract the helpers**

In `Mistty/Models/WindowsStore+Snapshot.swift`:

1. Add `snapshotWindow` and make `takeSnapshot` use it:

```swift
  /// Snapshot one window. Shared by takeSnapshot() (quit-restore) and
  /// closeWindow() (recently-closed stack) so a new snapshot field can't
  /// be added to one path and silently dropped from the other.
  func snapshotWindow(_ window: WindowState) -> WindowSnapshot {
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
            let paneLookup = Dictionary(uniqueKeysWithValues: tab.panes.map { ($0.id, $0) })
            return TabSnapshot(
              id: tab.id,
              customTitle: tab.customTitle,
              directory: tab.directory,
              layout: snapshotLayout(tab.layout.root, panes: paneLookup),
              activePaneID: tab.activePane?.id
            )
          },
          activeTabID: session.activeTab?.id
        )
      },
      activeSessionID: window.activeSession?.id
    )
  }

  func takeSnapshot() -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      version: WorkspaceSnapshot.currentVersion,
      windows: windows.map { snapshotWindow($0) },
      activeWindowID: activeWindow?.id
    )
  }
```

2. Add `restoreSessions` and make `restore(from:config:)` use it:

```swift
  /// Rehydrate sessions from snapshots into `state`. `mintSessionIDs` is
  /// true for reopen-closed-window (session IDs are surfaced via
  /// sidebar/IPC; a stale ID across close/reopen would be confusing) and
  /// false for quit-restore (IDs preserved; counters advanced by caller).
  func restoreSessions(
    from snapshots: [SessionSnapshot], into state: WindowState,
    config: RestoreConfig, mintSessionIDs: Bool,
    maxSessionID: inout Int, maxTabID: inout Int, maxPaneID: inout Int
  ) {
    let tabIDGen: () -> Int = { [weak self] in self?.generateTabID() ?? 0 }
    let paneIDGen: () -> Int = { [weak self] in self?.generatePaneID() ?? 0 }
    let popupIDGen: () -> Int = { [weak self] in self?.generatePopupID() ?? 0 }

    for sessionSnap in snapshots {
      maxSessionID = max(maxSessionID, sessionSnap.id)
      let session = MisttySession(
        id: mintSessionIDs ? generateSessionID() : sessionSnap.id,
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
  }
```

In `restore(from:config:)`, replace the inner per-window session loop (the `for sessionSnap in windowSnap.sessions { ... }` block) with a call to `restoreSessions(from: windowSnap.sessions, into: state, config: config, mintSessionIDs: false, maxSessionID: &maxSessionID, maxTabID: &maxTabID, maxPaneID: &maxPaneID)`, keeping the surrounding window-level logic (window creation, `activeSessionID` resolution, `pendingRestoreStates.append`) unchanged.

3. In `Mistty/Models/WindowsStore.swift`:
- `closeWindow`: replace the inline `let snapshot = WindowSnapshot(...)` construction (the whole multi-line literal) with `let snapshot = snapshotWindow(state)`.
- `reopenMostRecentClosed`: replace the body after `recentlyClosed.removeFirst()` with:

```swift
    let state = WindowState(id: reserveNextWindowID(), store: self)
    let config = MisttyConfig.current.restore
    // Counters were already advanced past these IDs when the window was
    // live; the max-tracking outputs are unused on this path.
    var maxSessionID = 0
    var maxTabID = 0
    var maxPaneID = 0
    restoreSessions(
      from: snapshot.sessions, into: state, config: config, mintSessionIDs: true,
      maxSessionID: &maxSessionID, maxTabID: &maxTabID, maxPaneID: &maxPaneID)
    state.activeSession = state.sessions.first
    pendingRestoreStates.append(state)
    return state.id
```
(Keep the existing explanatory comment about fresh session IDs above the call.)

- [ ] **Step 4: Verify**

Run: `swift test --skip Benchmark --filter "WindowsStoreSnapshotTests|WorkspaceSnapshotTests|WorkspaceSnapshotMigrationTests|SessionCloseTeardownTests" 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS including the new test. Then the full suite — only the 23 known snapshot failures.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/WindowsStore.swift Mistty/Models/WindowsStore+Snapshot.swift MisttyTests/Snapshot/WindowsStoreSnapshotTests.swift
git commit -m "refactor(store): share snapshotWindow/restoreSessions between close+reopen and quit-restore

closeWindow inlined a copy of the per-window snapshot and
reopenMostRecentClosed re-implemented the session-rehydration loop —
new snapshot fields had to be added twice or reopen silently lost them.
Reopen now also honors activeTabID instead of always activating the
first tab.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Final verification

- [ ] Full suite: only the 23 known `ChromePolishSnapshotTests` failures.
- [ ] `git log --oneline` shows one commit per task.

## Done in a separate inline pass after this wave merges (do NOT do in these workstreams)

Dead-code removal (touches files owned by multiple workstreams above): `ContentView.resizeActivePane(delta:along:)`, `IPCService.notImplemented`, `CopyModeAction.yank(text:)` + its `case .yank: break` handler, `PendingMotion.lineDown/.lineUp` + dead switch branches, `MisttyIPC.serviceName`, the vestigial `MisttyServiceProtocol` conformance, and the placeholder `MisttyTests/MisttyTests.swift`.

## Explicitly deferred

- **FuzzyMatcher ASCII/Unicode merge** — deliberate perf fast-path; revisit only with benchmarks in hand (`FuzzyMatcherBenchmarkTests` exists for that).
- **IPC request envelope / structured errors / dispatch table** — Wave 4 (protocol change, needs versioning design).
