# State Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Mistty wake up the way it quit — restore all sessions, tabs, and split panes in place with each pane's shell starting at the saved CWD, and optionally relaunch allowlisted programs (`nvim`, `claude`, `ssh`) with a user-configurable strategy.

**Architecture:** Codable `WorkspaceSnapshot` DTO layer in `MisttyShared/Snapshot/`. App-level AppKit state restoration (`applicationSupportsSecureRestorableState`) — encode/decode the JSON-serialized snapshot as an opaque `Data` blob via `NSApplicationDelegate`. Foreground process detection via `tcgetpgrp(pty_fd)` (primary) with shell-PID descendant walk (fallback); both paths require small libghostty patches. Allowlist lookup happens at restore time, so config edits between quit and relaunch take effect.

**Tech Stack:** Swift 6 / SwiftUI + AppKit (macOS 14+), XCTest, TOMLKit, libghostty (patched), Darwin `proc_*` / `sysctl` APIs.

**Spec:** `docs/superpowers/specs/2026-04-22-state-restoration-design.md`

---

## File Structure

### New files

| File | Role |
| --- | --- |
| `MisttyShared/Snapshot/WorkspaceSnapshot.swift` | Top-level snapshot DTO (`version`, `sessions`, `activeSessionID`). |
| `MisttyShared/Snapshot/SessionSnapshot.swift` | Per-session fields. |
| `MisttyShared/Snapshot/TabSnapshot.swift` | Per-tab fields; owns a `LayoutNodeSnapshot` tree. |
| `MisttyShared/Snapshot/LayoutNodeSnapshot.swift` | Indirect enum; `.leaf(pane:)` / `.split(...)`. Includes `SplitDirectionSnapshot`, `CapturedProcess`, `PaneSnapshot`. |
| `MisttyShared/Snapshot/RestoreConfig.swift` | Allowlist types + resolver (`RestoreCommandRule`, `RestoreConfig.resolve(_:)`). |
| `Mistty/Models/SessionStore+Snapshot.swift` | `takeSnapshot()` and `restore(from:config:)` extensions. |
| `Mistty/Support/ForegroundProcess.swift` | `ForegroundProcess` struct and `ForegroundProcessResolver` (primary + fallback). |
| `Mistty/App/AppDelegate.swift` | `NSApplicationDelegate` with encode/decode hooks and state wiring. |
| `Mistty/Services/StateRestorationObserver.swift` | Observes mutation and calls `NSApp.invalidateRestorableState()`. |
| `MisttyCLI/Commands/DebugCommand.swift` | `mistty-cli debug state` subcommand. |
| `MisttyShared/Models/StateSnapshotResponse.swift` | IPC response wrapper for the snapshot JSON. |
| `patches/ghostty/0002-expose-shell-pid.patch` | Adds `ghostty_surface_command_pid(surface) -> pid_t`. |
| `patches/ghostty/0003-expose-pty-slave-fd.patch` | Adds `ghostty_surface_pty_fd(surface) -> c_int`. |
| `MisttyTests/Snapshot/WorkspaceSnapshotTests.swift` | Codable round-trip, version rejection. |
| `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift` | `takeSnapshot` / `restore` coverage. |
| `MisttyTests/Config/RestoreConfigTests.swift` | Parsing, matching, argv shell-joining. |
| `MisttyTests/Support/ForegroundProcessResolverTests.swift` | Fallback order + shell-detect via injected seams. |

### Modified files

| File | Change |
| --- | --- |
| `Mistty/App/MisttyApp.swift` | Add `@NSApplicationDelegateAdaptor(AppDelegate.self)`; wire store + observer into delegate from `init()`. |
| `Mistty/Models/MisttyPane.swift` | Add `shellPID`, `ptyFD` accessors that proxy to `surfaceView.surface`. |
| `Mistty/Config/MisttyConfig.swift` | Add `restore: RestoreConfig` field; parse `[[restore.command]]`; serialize in `save()`. |
| `Mistty/Services/IPCService.swift` | Add `getStateSnapshot()` returning JSON Data. |
| `Mistty/Services/IPCListener.swift` | Route `getStateSnapshot` RPC. |
| `MisttyShared/MisttyServiceProtocol.swift` | Declare `getStateSnapshot`. |
| `MisttyCLI/MisttyCLI.swift` | Register `DebugCommand`. |
| `docs/config-example.toml` | Sample `[[restore.command]]` block. |

---

## Prerequisite: work in a worktree

This is a multi-phase, multi-patch change. Work in a dedicated worktree to keep `main` uncluttered.

- [ ] **Setup: create worktree**

```bash
cd /Users/manu/Developer/mistty
git worktree add .worktrees/state-restoration -b feat/state-restoration
just setup-worktree .worktrees/state-restoration
cd .worktrees/state-restoration
```

Then execute all tasks below from `.worktrees/state-restoration`.

---

## Phase 1 — Snapshot DTO layer + round-trip

Pure scaffolding. Produces no user-visible change. Leaves `main` shippable.

### Task 1: `RestoreCommandRule` + `RestoreConfig` types (TDD)

**Files:**
- Create: `MisttyShared/Snapshot/RestoreConfig.swift`
- Create: `MisttyTests/Config/RestoreConfigTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MisttyTests/Config/RestoreConfigTests.swift`:

```swift
import XCTest
@testable import MisttyShared

final class RestoreConfigTests: XCTestCase {
  func test_resolve_returnsNilWhenNoRuleMatches() {
    let config = RestoreConfig(commands: [.init(match: "nvim", strategy: nil)])
    let captured = CapturedProcess(executable: "htop", argv: ["htop"])
    XCTAssertNil(config.resolve(captured))
  }

  func test_resolve_returnsStrategyWhenRuleHasOne() {
    let config = RestoreConfig(commands: [.init(match: "claude", strategy: "claude --resume")])
    let captured = CapturedProcess(executable: "claude", argv: ["claude", "session-1"])
    XCTAssertEqual(config.resolve(captured), "claude --resume")
  }

  func test_resolve_replaysArgvWhenStrategyAbsent() {
    let config = RestoreConfig(commands: [.init(match: "nvim", strategy: nil)])
    let captured = CapturedProcess(executable: "nvim", argv: ["nvim", "mytext.txt"])
    XCTAssertEqual(config.resolve(captured), "nvim mytext.txt")
  }

  func test_resolve_shellQuotesArgvElementsWithSpaces() {
    let config = RestoreConfig(commands: [.init(match: "less", strategy: nil)])
    let captured = CapturedProcess(executable: "less", argv: ["less", "my file.log"])
    XCTAssertEqual(config.resolve(captured), "less 'my file.log'")
  }

  func test_resolve_shellQuotesArgvElementsWithSingleQuotes() {
    let config = RestoreConfig(commands: [.init(match: "echo", strategy: nil)])
    let captured = CapturedProcess(executable: "echo", argv: ["echo", "it's fine"])
    XCTAssertEqual(config.resolve(captured), #"echo 'it'\''s fine'"#)
  }

  func test_resolve_firstMatchWins() {
    let config = RestoreConfig(commands: [
      .init(match: "ssh", strategy: "ssh --quiet"),
      .init(match: "ssh", strategy: "ssh -v"),
    ])
    let captured = CapturedProcess(executable: "ssh", argv: ["ssh", "host"])
    XCTAssertEqual(config.resolve(captured), "ssh --quiet")
  }

  func test_resolve_emptyStrategyReplaysArgv() {
    let config = RestoreConfig(commands: [.init(match: "vim", strategy: "")])
    let captured = CapturedProcess(executable: "vim", argv: ["vim", "foo"])
    XCTAssertEqual(config.resolve(captured), "vim foo")
  }
}
```

- [ ] **Step 2: Run tests, confirm they fail to compile**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
```

Expected: build errors because `RestoreConfig`, `RestoreCommandRule`, and `CapturedProcess` don't exist yet.

- [ ] **Step 3: Create the types**

Create `MisttyShared/Snapshot/RestoreConfig.swift`:

```swift
import Foundation

public struct RestoreCommandRule: Codable, Sendable, Equatable {
  /// Exact match against the foreground process's executable basename.
  public var match: String
  /// Command string to run on restore. `nil` (or empty) ⇒ replay captured argv.
  public var strategy: String?

  public init(match: String, strategy: String? = nil) {
    self.match = match
    self.strategy = strategy
  }
}

public struct RestoreConfig: Codable, Sendable, Equatable {
  public var commands: [RestoreCommandRule]

  public init(commands: [RestoreCommandRule] = []) {
    self.commands = commands
  }

  /// Resolve a captured foreground process to a command string. Returns `nil`
  /// when no allowlist rule matches (caller should restore a bare shell).
  public func resolve(_ captured: CapturedProcess) -> String? {
    guard let rule = commands.first(where: { $0.match == captured.executable })
    else { return nil }
    if let strategy = rule.strategy, !strategy.isEmpty {
      return strategy
    }
    return Self.shellJoin(captured.argv)
  }

  /// POSIX single-quote escape any argv element that contains shell
  /// metacharacters; join with single spaces.
  static func shellJoin(_ argv: [String]) -> String {
    argv.map { arg in
      if arg.allSatisfy(isSafeShellChar) { return arg }
      let escaped = arg.replacingOccurrences(of: "'", with: #"'\''"#)
      return "'\(escaped)'"
    }.joined(separator: " ")
  }

  private static func isSafeShellChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || "_-./:@,+=".contains(c)
  }
}

/// Captured at save time; stored in `PaneSnapshot.captured`. Strategy
/// resolution happens at RESTORE time so config edits take effect.
public struct CapturedProcess: Codable, Sendable, Equatable {
  public var executable: String
  public var argv: [String]

  public init(executable: String, argv: [String]) {
    self.executable = executable
    self.argv = argv
  }
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "(RestoreConfigTests|failed|passed)" /tmp/mistty-test.log
```

Expected: `Test Suite 'RestoreConfigTests' passed` and all 7 tests green.

- [ ] **Step 5: Commit**

```bash
git add MisttyShared/Snapshot/RestoreConfig.swift MisttyTests/Config/RestoreConfigTests.swift
git commit -m "feat(restore): RestoreConfig + CapturedProcess + shell-joining resolver"
```

---

### Task 2: Parse `[[restore.command]]` in `MisttyConfig` (TDD)

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift`
- Modify: `MisttyTests/Config/MisttyConfigTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `MisttyTests/Config/MisttyConfigTests.swift` (add inside the existing class):

```swift
  func test_parse_restoreCommand_emptyByDefault() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertEqual(config.restore, RestoreConfig())
  }

  func test_parse_restoreCommand_singleRuleWithoutStrategy() throws {
    let toml = """
    [[restore.command]]
    match = "nvim"
    """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.restore.commands, [.init(match: "nvim", strategy: nil)])
  }

  func test_parse_restoreCommand_multipleRulesPreserveOrder() throws {
    let toml = """
    [[restore.command]]
    match = "claude"
    strategy = "claude --resume"

    [[restore.command]]
    match = "nvim"
    """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.restore.commands, [
      .init(match: "claude", strategy: "claude --resume"),
      .init(match: "nvim", strategy: nil),
    ])
  }

  func test_save_restoreCommand_roundTrip() throws {
    var config = MisttyConfig()
    config.restore = RestoreConfig(commands: [
      .init(match: "nvim", strategy: nil),
      .init(match: "claude", strategy: "claude --resume"),
    ])
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-restore-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.restore, config.restore)
  }
```

- [ ] **Step 2: Run tests, confirm failure**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
```

Expected: build error — `MisttyConfig` has no `restore` property.

- [ ] **Step 3: Add `restore` field and TOML parser hook**

Open `Mistty/Config/MisttyConfig.swift`. Add the import if missing (`import MisttyShared` should already be there). Add a new stored property to `MisttyConfig`:

```swift
  var restore: RestoreConfig = RestoreConfig()
```

Place it next to the other sub-config fields (after `ghostty: GhosttyPassthroughConfig`). Then, inside `MisttyConfig.parse(_:)`, add the parser block before the final `return config` (near the existing `[ssh]` / `[copy_mode]` parsing blocks):

```swift
    if let restoreTable = table["restore"]?.table,
       let commandArray = restoreTable["command"]?.array {
      config.restore.commands = commandArray.compactMap { entry -> RestoreCommandRule? in
        guard let t = entry.table,
              let match = t["match"]?.string, !match.isEmpty
        else { return nil }
        let strategy = t["strategy"]?.string
        return RestoreCommandRule(
          match: match,
          strategy: (strategy?.isEmpty == true) ? nil : strategy
        )
      }
    }
```

- [ ] **Step 4: Add `save()` serializer for the restore block**

In the same file, inside `func save(to url: URL = configURL)`, after the existing `[ghostty]` block emission and before `try lines.joined(...)`:

```swift
    if !restore.commands.isEmpty {
      for rule in restore.commands {
        lines.append("")
        lines.append("[[restore.command]]")
        lines.append("match = \"\(tomlEscape(rule.match))\"")
        if let strategy = rule.strategy, !strategy.isEmpty {
          lines.append("strategy = \"\(tomlEscape(strategy))\"")
        }
      }
    }
```

- [ ] **Step 5: Run tests, confirm they pass**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "(test_parse_restoreCommand|test_save_restoreCommand|failed:)" /tmp/mistty-test.log
```

Expected: all 4 new tests green; no regressions.

- [ ] **Step 6: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift MisttyTests/Config/MisttyConfigTests.swift
git commit -m "feat(config): parse [[restore.command]] allowlist"
```

---

### Task 3: `SplitDirectionSnapshot` + `LayoutNodeSnapshot` + `PaneSnapshot` (TDD)

**Files:**
- Create: `MisttyShared/Snapshot/LayoutNodeSnapshot.swift`
- Create: `MisttyTests/Snapshot/WorkspaceSnapshotTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MisttyTests/Snapshot/WorkspaceSnapshotTests.swift`:

```swift
import XCTest
@testable import MisttyShared

final class WorkspaceSnapshotTests: XCTestCase {
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }

  func test_paneSnapshot_roundTrip() throws {
    let pane = PaneSnapshot(
      id: 5,
      directory: URL(fileURLWithPath: "/tmp"),
      currentWorkingDirectory: URL(fileURLWithPath: "/tmp/work"),
      captured: CapturedProcess(executable: "nvim", argv: ["nvim", "foo.txt"])
    )
    XCTAssertEqual(try roundTrip(pane), pane)
  }

  func test_paneSnapshot_roundTripWithoutCaptured() throws {
    let pane = PaneSnapshot(id: 1, directory: nil, currentWorkingDirectory: nil, captured: nil)
    XCTAssertEqual(try roundTrip(pane), pane)
  }

  func test_layoutLeaf_roundTrip() throws {
    let leaf = LayoutNodeSnapshot.leaf(pane: PaneSnapshot(id: 1))
    XCTAssertEqual(try roundTrip(leaf), leaf)
  }

  func test_layoutSplit_roundTrip() throws {
    let split = LayoutNodeSnapshot.split(
      direction: .horizontal,
      a: .leaf(pane: PaneSnapshot(id: 1)),
      b: .leaf(pane: PaneSnapshot(id: 2)),
      ratio: 0.4
    )
    XCTAssertEqual(try roundTrip(split), split)
  }

  func test_layoutNested_roundTrip() throws {
    let tree = LayoutNodeSnapshot.split(
      direction: .vertical,
      a: .split(
        direction: .horizontal,
        a: .leaf(pane: PaneSnapshot(id: 1)),
        b: .leaf(pane: PaneSnapshot(id: 2)),
        ratio: 0.6
      ),
      b: .leaf(pane: PaneSnapshot(id: 3)),
      ratio: 0.5
    )
    XCTAssertEqual(try roundTrip(tree), tree)
  }
}
```

Also add the convenience init so the tests compile:

- [ ] **Step 2: Run tests, confirm failure**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
```

Expected: build errors — types don't exist yet.

- [ ] **Step 3: Create `LayoutNodeSnapshot.swift` with `PaneSnapshot` + `SplitDirectionSnapshot` co-located**

Create `MisttyShared/Snapshot/LayoutNodeSnapshot.swift`:

```swift
import Foundation

public enum SplitDirectionSnapshot: String, Codable, Sendable {
  case horizontal
  case vertical
}

public struct PaneSnapshot: Codable, Sendable, Equatable {
  public let id: Int
  /// Initial directory used when the pane was originally created.
  public var directory: URL?
  /// Live OSC 7 CWD at save time. Used as the spawn directory on restore.
  public var currentWorkingDirectory: URL?
  /// Captured foreground process. `nil` ⇒ bare shell on restore.
  public var captured: CapturedProcess?

  public init(
    id: Int,
    directory: URL? = nil,
    currentWorkingDirectory: URL? = nil,
    captured: CapturedProcess? = nil
  ) {
    self.id = id
    self.directory = directory
    self.currentWorkingDirectory = currentWorkingDirectory
    self.captured = captured
  }
}

public indirect enum LayoutNodeSnapshot: Codable, Sendable, Equatable {
  case leaf(pane: PaneSnapshot)
  case split(
    direction: SplitDirectionSnapshot,
    a: LayoutNodeSnapshot,
    b: LayoutNodeSnapshot,
    ratio: Double
  )
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "(WorkspaceSnapshotTests|failed:)" /tmp/mistty-test.log
```

Expected: 5 tests pass under `WorkspaceSnapshotTests`.

- [ ] **Step 5: Commit**

```bash
git add MisttyShared/Snapshot/LayoutNodeSnapshot.swift MisttyTests/Snapshot/WorkspaceSnapshotTests.swift
git commit -m "feat(snapshot): LayoutNodeSnapshot + PaneSnapshot + SplitDirectionSnapshot"
```

---

### Task 4: `TabSnapshot` + `SessionSnapshot` + `WorkspaceSnapshot` (TDD)

**Files:**
- Create: `MisttyShared/Snapshot/TabSnapshot.swift`
- Create: `MisttyShared/Snapshot/SessionSnapshot.swift`
- Create: `MisttyShared/Snapshot/WorkspaceSnapshot.swift`
- Modify: `MisttyTests/Snapshot/WorkspaceSnapshotTests.swift`

- [ ] **Step 1: Append failing tests**

Add these tests to `MisttyTests/Snapshot/WorkspaceSnapshotTests.swift`:

```swift
  func test_workspaceSnapshot_roundTrip() throws {
    let workspace = WorkspaceSnapshot(
      version: 1,
      sessions: [
        SessionSnapshot(
          id: 1,
          name: "work",
          customName: "Work",
          directory: URL(fileURLWithPath: "/tmp"),
          sshCommand: nil,
          lastActivatedAt: Date(timeIntervalSince1970: 1_700_000_000),
          tabs: [
            TabSnapshot(
              id: 10,
              customTitle: "repl",
              directory: URL(fileURLWithPath: "/tmp"),
              layout: .leaf(pane: PaneSnapshot(id: 100)),
              activePaneID: 100
            ),
          ],
          activeTabID: 10
        ),
      ],
      activeSessionID: 1
    )
    XCTAssertEqual(try roundTrip(workspace), workspace)
  }

  func test_workspaceSnapshot_unknownVersionRejected() throws {
    let bogus = #"{"version": 999, "sessions": [], "activeSessionID": null}"#
    let decoder = JSONDecoder()
    let workspace = try decoder.decode(WorkspaceSnapshot.self, from: Data(bogus.utf8))
    XCTAssertNotNil(workspace.unsupportedVersion)
    XCTAssertEqual(workspace.unsupportedVersion, 999)
  }

  func test_workspaceSnapshot_knownVersionAccepted() throws {
    let good = #"{"version": 1, "sessions": [], "activeSessionID": null}"#
    let decoder = JSONDecoder()
    let workspace = try decoder.decode(WorkspaceSnapshot.self, from: Data(good.utf8))
    XCTAssertNil(workspace.unsupportedVersion)
    XCTAssertTrue(workspace.sessions.isEmpty)
  }
```

- [ ] **Step 2: Run tests, confirm failure**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
```

Expected: build errors for missing types.

- [ ] **Step 3: Create the three types**

Create `MisttyShared/Snapshot/TabSnapshot.swift`:

```swift
import Foundation

public struct TabSnapshot: Codable, Sendable, Equatable {
  public let id: Int
  public var customTitle: String?
  public var directory: URL?
  public var layout: LayoutNodeSnapshot
  public var activePaneID: Int?

  public init(
    id: Int,
    customTitle: String? = nil,
    directory: URL? = nil,
    layout: LayoutNodeSnapshot,
    activePaneID: Int? = nil
  ) {
    self.id = id
    self.customTitle = customTitle
    self.directory = directory
    self.layout = layout
    self.activePaneID = activePaneID
  }
}
```

Create `MisttyShared/Snapshot/SessionSnapshot.swift`:

```swift
import Foundation

public struct SessionSnapshot: Codable, Sendable, Equatable {
  public let id: Int
  public var name: String
  public var customName: String?
  public var directory: URL
  public var sshCommand: String?
  public var lastActivatedAt: Date
  public var tabs: [TabSnapshot]
  public var activeTabID: Int?

  public init(
    id: Int,
    name: String,
    customName: String? = nil,
    directory: URL,
    sshCommand: String? = nil,
    lastActivatedAt: Date,
    tabs: [TabSnapshot],
    activeTabID: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.customName = customName
    self.directory = directory
    self.sshCommand = sshCommand
    self.lastActivatedAt = lastActivatedAt
    self.tabs = tabs
    self.activeTabID = activeTabID
  }
}
```

Create `MisttyShared/Snapshot/WorkspaceSnapshot.swift`:

```swift
import Foundation

public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
  /// Current schema version. The decoder records an unsupported version
  /// in `unsupportedVersion` instead of throwing; callers inspect that
  /// field and decide whether to bail or migrate.
  public static let currentVersion = 1

  public var version: Int
  public var sessions: [SessionSnapshot]
  public var activeSessionID: Int?

  /// Non-nil when the decoded `version` field isn't understood by this
  /// build. Callers should treat non-nil as "bail, start empty."
  public var unsupportedVersion: Int? {
    version == Self.currentVersion ? nil : version
  }

  public init(
    version: Int = WorkspaceSnapshot.currentVersion,
    sessions: [SessionSnapshot] = [],
    activeSessionID: Int? = nil
  ) {
    self.version = version
    self.sessions = sessions
    self.activeSessionID = activeSessionID
  }
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "(WorkspaceSnapshotTests|failed:)" /tmp/mistty-test.log
```

Expected: 3 new tests pass on top of the 5 from Task 3.

- [ ] **Step 5: Commit**

```bash
git add MisttyShared/Snapshot/TabSnapshot.swift MisttyShared/Snapshot/SessionSnapshot.swift MisttyShared/Snapshot/WorkspaceSnapshot.swift MisttyTests/Snapshot/WorkspaceSnapshotTests.swift
git commit -m "feat(snapshot): TabSnapshot + SessionSnapshot + WorkspaceSnapshot"
```

---

### Task 5: `SessionStore.takeSnapshot()` (TDD)

**Files:**
- Create: `Mistty/Models/SessionStore+Snapshot.swift`
- Create: `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift`:

```swift
import XCTest
@testable import Mistty
@testable import MisttyShared

@MainActor
final class SessionStoreSnapshotTests: XCTestCase {
  private var store: SessionStore!

  override func setUp() async throws {
    await MainActor.run {
      store = SessionStore()
    }
  }

  func test_takeSnapshot_emptyStoreProducesEmptySessions() {
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.version, WorkspaceSnapshot.currentVersion)
    XCTAssertTrue(snapshot.sessions.isEmpty)
    XCTAssertNil(snapshot.activeSessionID)
  }

  func test_takeSnapshot_capturesSingleSessionWithOnePane() {
    let session = store.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.sessions.count, 1)
    XCTAssertEqual(snapshot.activeSessionID, session.id)
    XCTAssertEqual(snapshot.sessions[0].tabs.count, 1)
    guard case .leaf(let pane) = snapshot.sessions[0].tabs[0].layout else {
      return XCTFail("expected single leaf")
    }
    XCTAssertEqual(pane.id, session.tabs[0].panes[0].id)
  }

  func test_takeSnapshot_capturesSplitLayout() {
    let session = store.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    let snapshot = store.takeSnapshot()
    guard case .split(let dir, _, _, _) = snapshot.sessions[0].tabs[0].layout else {
      return XCTFail("expected split root")
    }
    XCTAssertEqual(dir, .horizontal)
  }

  func test_takeSnapshot_preservesCustomNames() {
    let session = store.createSession(
      name: "work", directory: URL(fileURLWithPath: "/tmp"), customName: "Work")
    session.tabs[0].customTitle = "repl"
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.sessions[0].customName, "Work")
    XCTAssertEqual(snapshot.sessions[0].tabs[0].customTitle, "repl")
  }

  func test_takeSnapshot_preservesSSHCommand() {
    let session = store.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    session.sshCommand = "ssh user@host"
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.sessions[0].sshCommand, "ssh user@host")
  }

  func test_takeSnapshot_preservesActiveIDs() {
    let s = store.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    s.addTab()
    let secondTab = s.tabs[1]
    s.activeTab = secondTab
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.activeSessionID, s.id)
    XCTAssertEqual(snapshot.sessions[0].activeTabID, secondTab.id)
    XCTAssertEqual(snapshot.sessions[0].tabs[1].activePaneID, secondTab.panes[0].id)
  }
}
```

- [ ] **Step 2: Run, confirm failure**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
```

Expected: build error — `takeSnapshot()` doesn't exist.

- [ ] **Step 3: Implement `takeSnapshot()`**

Create `Mistty/Models/SessionStore+Snapshot.swift`:

```swift
import Foundation
import MisttyShared

extension SessionStore {
  func takeSnapshot() -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      version: WorkspaceSnapshot.currentVersion,
      sessions: sessions.map { session in
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
              layout: snapshotLayout(tab.layout.root, activePaneID: tab.activePane?.id),
              activePaneID: tab.activePane?.id
            )
          },
          activeTabID: session.activeTab?.id
        )
      },
      activeSessionID: activeSession?.id
    )
  }

  private func snapshotLayout(
    _ node: PaneLayoutNode,
    activePaneID: Int?
  ) -> LayoutNodeSnapshot {
    switch node {
    case .leaf(let pane):
      return .leaf(pane: PaneSnapshot(
        id: pane.id,
        directory: pane.directory,
        currentWorkingDirectory: pane.currentWorkingDirectory,
        captured: nil  // filled in by Phase 2
      ))
    case .empty:
      // Shouldn't appear in a healthy tree, but emit a placeholder leaf with
      // id 0 rather than crashing. The decoder treats id 0 as a sentinel.
      return .leaf(pane: PaneSnapshot(id: 0))
    case .split(let dir, let a, let b, let ratio):
      return .split(
        direction: dir == .horizontal ? .horizontal : .vertical,
        a: snapshotLayout(a, activePaneID: activePaneID),
        b: snapshotLayout(b, activePaneID: activePaneID),
        ratio: Double(ratio)
      )
    }
  }
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "(SessionStoreSnapshotTests|failed:)" /tmp/mistty-test.log
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/SessionStore+Snapshot.swift MisttyTests/Snapshot/SessionStoreSnapshotTests.swift
git commit -m "feat(snapshot): SessionStore.takeSnapshot()"
```

---

### Task 6: `SessionStore.restore(from:config:)` (TDD)

**Files:**
- Modify: `Mistty/Models/SessionStore+Snapshot.swift`
- Modify: `Mistty/Models/SessionStore.swift` — expose ID-counter reset helper
- Modify: `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift`

- [ ] **Step 1: Append failing tests**

Add to `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift`:

```swift
  func test_restore_emptyWorkspaceLeavesStoreEmpty() {
    _ = store.createSession(name: "leftover", directory: URL(fileURLWithPath: "/tmp"))
    store.restore(from: WorkspaceSnapshot(), config: RestoreConfig())
    XCTAssertTrue(store.sessions.isEmpty)
    XCTAssertNil(store.activeSession)
  }

  func test_restore_rebuildsSingleSession() {
    let snapshot = WorkspaceSnapshot(
      version: 1,
      sessions: [
        SessionSnapshot(
          id: 7,
          name: "work",
          customName: "Work",
          directory: URL(fileURLWithPath: "/tmp"),
          sshCommand: nil,
          lastActivatedAt: Date(),
          tabs: [
            TabSnapshot(
              id: 3,
              customTitle: nil,
              directory: URL(fileURLWithPath: "/tmp"),
              layout: .leaf(pane: PaneSnapshot(id: 42)),
              activePaneID: 42
            ),
          ],
          activeTabID: 3
        ),
      ],
      activeSessionID: 7
    )
    store.restore(from: snapshot, config: RestoreConfig())
    XCTAssertEqual(store.sessions.count, 1)
    XCTAssertEqual(store.sessions[0].id, 7)
    XCTAssertEqual(store.sessions[0].customName, "Work")
    XCTAssertEqual(store.activeSession?.id, 7)
    XCTAssertEqual(store.sessions[0].tabs[0].id, 3)
    XCTAssertEqual(store.sessions[0].tabs[0].panes[0].id, 42)
  }

  func test_restore_rebuildsSplitLayout() {
    let snapshot = WorkspaceSnapshot(
      sessions: [
        SessionSnapshot(
          id: 1, name: "w",
          directory: URL(fileURLWithPath: "/tmp"),
          lastActivatedAt: Date(),
          tabs: [
            TabSnapshot(
              id: 1,
              layout: .split(
                direction: .horizontal,
                a: .leaf(pane: PaneSnapshot(id: 10)),
                b: .leaf(pane: PaneSnapshot(id: 11)),
                ratio: 0.3
              ),
              activePaneID: 11
            ),
          ],
          activeTabID: 1
        ),
      ],
      activeSessionID: 1
    )
    store.restore(from: snapshot, config: RestoreConfig())
    let tab = store.sessions[0].tabs[0]
    XCTAssertEqual(tab.panes.count, 2)
    XCTAssertEqual(tab.activePane?.id, 11)
    guard case .split(let dir, _, _, let ratio) = tab.layout.root else {
      return XCTFail("expected split")
    }
    XCTAssertEqual(dir, .horizontal)
    XCTAssertEqual(ratio, 0.3, accuracy: 0.0001)
  }

  func test_restore_advancesIDCountersPastMax() {
    let snapshot = WorkspaceSnapshot(
      sessions: [
        SessionSnapshot(
          id: 50, name: "w",
          directory: URL(fileURLWithPath: "/tmp"),
          lastActivatedAt: Date(),
          tabs: [
            TabSnapshot(
              id: 30,
              layout: .leaf(pane: PaneSnapshot(id: 99)),
              activePaneID: 99
            ),
          ],
          activeTabID: 30
        ),
      ],
      activeSessionID: 50
    )
    store.restore(from: snapshot, config: RestoreConfig())
    let fresh = store.createSession(name: "post", directory: URL(fileURLWithPath: "/tmp"))
    XCTAssertGreaterThan(fresh.id, 50)
    XCTAssertGreaterThan(fresh.tabs[0].id, 30)
    XCTAssertGreaterThan(fresh.tabs[0].panes[0].id, 99)
  }

  func test_restore_missingDirectoryFallsBackToHome() {
    let missing = URL(fileURLWithPath: "/definitely/not/real/path-\(UUID().uuidString)")
    let snapshot = WorkspaceSnapshot(
      sessions: [
        SessionSnapshot(
          id: 1, name: "w",
          directory: URL(fileURLWithPath: "/tmp"),
          lastActivatedAt: Date(),
          tabs: [
            TabSnapshot(
              id: 1,
              layout: .leaf(pane: PaneSnapshot(
                id: 1,
                directory: missing,
                currentWorkingDirectory: missing,
                captured: nil
              )),
              activePaneID: 1
            ),
          ],
          activeTabID: 1
        ),
      ],
      activeSessionID: 1
    )
    store.restore(from: snapshot, config: RestoreConfig())
    let home = FileManager.default.homeDirectoryForCurrentUser
    XCTAssertEqual(store.sessions[0].tabs[0].panes[0].directory, home)
  }

  func test_restore_roundTrip_preservesStructure() {
    let s = store.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    s.tabs[0].splitActivePane(direction: .vertical)
    s.addTab()
    let snapshot = store.takeSnapshot()
    let second = SessionStore()
    second.restore(from: snapshot, config: RestoreConfig())
    let beforeIDs = s.tabs.map { $0.id }
    let afterIDs = second.sessions[0].tabs.map { $0.id }
    XCTAssertEqual(beforeIDs, afterIDs)
    XCTAssertEqual(second.sessions[0].tabs[0].panes.count, 2)
  }
```

- [ ] **Step 2: Run tests, confirm failure**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
```

Expected: build error — `restore(from:config:)` doesn't exist.

- [ ] **Step 3: Add ID-counter reset helper to `SessionStore`**

Open `Mistty/Models/SessionStore.swift`. Near the other private helpers (around line 25), add:

```swift
  /// Advance the next-ID counters so newly-allocated IDs don't collide with
  /// restored ones. Called once from `restore(from:config:)`.
  fileprivate func advanceIDCounters(
    sessionMax: Int, tabMax: Int, paneMax: Int, popupMax: Int = 0
  ) {
    nextSessionId = max(nextSessionId, sessionMax + 1)
    nextTabId = max(nextTabId, tabMax + 1)
    nextPaneId = max(nextPaneId, paneMax + 1)
    nextPopupId = max(nextPopupId, popupMax + 1)
  }
```

Also remove `private` from the three counter fields (make them `fileprivate`) so the extension in the same module can reach them:

```swift
  fileprivate var nextSessionId = 1
  fileprivate var nextTabId = 1
  fileprivate var nextPaneId = 1
  fileprivate var nextWindowId = 1
  fileprivate var nextPopupId = 1
```

- [ ] **Step 4: Implement `restore(from:config:)`**

In `Mistty/Models/SessionStore+Snapshot.swift`, append:

```swift
extension SessionStore {
  func restore(from snapshot: WorkspaceSnapshot, config: RestoreConfig) {
    guard snapshot.unsupportedVersion == nil else {
      DebugLog.shared.log(
        "restore",
        "unsupported snapshot version \(snapshot.version); starting empty")
      return
    }

    // Clear anything currently in the store before reconstructing.
    for session in sessions { closeSession(session) }

    var maxSessionID = 0, maxTabID = 0, maxPaneID = 0

    for sessionSnap in snapshot.sessions {
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

      // `MisttySession.init` adds a default tab; drop it before restoring.
      for tab in session.tabs { session.closeTab(tab) }

      for tabSnap in sessionSnap.tabs {
        maxTabID = max(maxTabID, tabSnap.id)
        let tab = Self.restoreTab(
          from: tabSnap,
          paneIDGen: paneIDGen,
          config: config,
          maxPaneID: &maxPaneID
        )
        session.addTabByRestore(tab)
      }

      if let activeTabID = sessionSnap.activeTabID,
         let activeTab = session.tabs.first(where: { $0.id == activeTabID }) {
        session.activeTab = activeTab
      } else {
        session.activeTab = session.tabs.first
      }

      appendRestoredSession(session)
    }

    if let activeID = snapshot.activeSessionID,
       let active = sessions.first(where: { $0.id == activeID }) {
      activeSession = active
    } else {
      activeSession = sessions.first
    }

    advanceIDCounters(
      sessionMax: maxSessionID, tabMax: maxTabID, paneMax: maxPaneID)
  }

  private static func restoreTab(
    from snapshot: TabSnapshot,
    paneIDGen: @escaping () -> Int,
    config: RestoreConfig,
    maxPaneID: inout Int
  ) -> MisttyTab {
    // Rebuild the layout tree from the snapshot, creating MisttyPane instances.
    var panes: [Int: MisttyPane] = [:]
    let rootNode = restoreLayoutNode(
      snapshot.layout, config: config, panes: &panes, maxPaneID: &maxPaneID)

    // Seed the tab with the first pane found, then replace layout.
    guard let firstPane = panes.values.first else {
      // Empty tree — unreachable for real snapshots; synthesize a fresh pane.
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

  private static func restoreLayoutNode(
    _ snapshot: LayoutNodeSnapshot,
    config: RestoreConfig,
    panes: inout [Int: MisttyPane],
    maxPaneID: inout Int
  ) -> PaneLayoutNode {
    switch snapshot {
    case .leaf(let paneSnap):
      maxPaneID = max(maxPaneID, paneSnap.id)
      let pane = MisttyPane(id: paneSnap.id)
      pane.directory = resolveCWD(
        paneSnap.currentWorkingDirectory ?? paneSnap.directory)
      pane.currentWorkingDirectory = paneSnap.currentWorkingDirectory
      if let captured = paneSnap.captured,
         let command = config.resolve(captured) {
        pane.command = command
        pane.useCommandField = true
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

  /// Pane directories that no longer exist fall back to the user's home
  /// directory so the spawned shell doesn't die immediately with "no such
  /// file." Matches behavior spelled out in the spec.
  private static func resolveCWD(_ url: URL?) -> URL? {
    guard let url else { return nil }
    let path = url.path
    if FileManager.default.fileExists(atPath: path) {
      return url
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }
}
```

- [ ] **Step 5: Add `SessionStore` helpers needed by restore**

Open `Mistty/Models/SessionStore.swift`. Add near the end of the class:

```swift
  /// Append a fully-constructed `MisttySession` during restore. Bypasses
  /// `createSession`'s fresh-ID + default-tab flow because the session is
  /// already hydrated from a snapshot.
  fileprivate func appendRestoredSession(_ session: MisttySession) {
    sessions.append(session)
  }

  /// Used by `restore` to reach the private counter helpers.
  fileprivate func generateTabID() -> Int {
    let id = nextTabId
    nextTabId += 1
    return id
  }

  fileprivate func generatePaneID() -> Int {
    let id = nextPaneId
    nextPaneId += 1
    return id
  }

  fileprivate func generatePopupID() -> Int {
    let id = nextPopupId
    nextPopupId += 1
    return id
  }
```

(Remove the two duplicate `private func generateTabID/generatePaneID` stubs already at the top of the file; they move into these `fileprivate` versions. Leave `generateSessionID` as-is — `appendRestoredSession` avoids it.)

- [ ] **Step 6: Add two small `MisttySession` / `MisttyTab` helpers**

Open `Mistty/Models/MisttySession.swift`. Near the existing `addTab` / `closeTab`, add:

```swift
  /// Append a pre-constructed `MisttyTab` during restore. Bypasses `addTab`'s
  /// fresh-tab creation flow because the tab is already hydrated from a
  /// snapshot.
  func addTabByRestore(_ tab: MisttyTab) {
    tabs.append(tab)
    activeTab = tab
  }
```

Open `Mistty/Models/MisttyTab.swift`. Add:

```swift
  /// Resync `panes` from the current `layout.leaves` after `restore` wires a
  /// new tree into the tab. Not needed in normal operation because
  /// split/close already keep them in sync.
  func refreshPanesFromLayout() {
    panes = layout.leaves
  }
```

- [ ] **Step 7: Run tests, confirm they pass**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "(SessionStoreSnapshotTests|failed:)" /tmp/mistty-test.log
```

Expected: all 12 `SessionStoreSnapshotTests` green.

- [ ] **Step 8: Commit**

```bash
git add Mistty/Models/SessionStore+Snapshot.swift Mistty/Models/SessionStore.swift Mistty/Models/MisttySession.swift Mistty/Models/MisttyTab.swift MisttyTests/Snapshot/SessionStoreSnapshotTests.swift
git commit -m "feat(snapshot): SessionStore.restore(from:config:)"
```

---

### Task 7: Update `docs/config-example.toml` with restore section

**Files:**
- Modify: `docs/config-example.toml`

- [ ] **Step 1: Append the restore example block**

Open `docs/config-example.toml`. After the last existing section (likely `[ghostty]`), append:

```toml

# ─────────────────────────────────────────────────────────────────────────────
# State restoration — allowlist of processes to relaunch on restore.
#
# When Mistty restarts, any pane where the captured foreground process's
# basename matches a rule below is relaunched. Omit `strategy` to replay the
# captured argv verbatim (preserves e.g. `nvim mytext.txt`). Set `strategy`
# to override — useful for tools with a dedicated resume flag.
#
# Non-allowlisted panes restore as a bare shell at the saved CWD.
# ─────────────────────────────────────────────────────────────────────────────

[[restore.command]]
match = "nvim"                 # replay argv → nvim mytext.txt comes back intact

[[restore.command]]
match = "vim"                  # aliases get their own entry

[[restore.command]]
match = "claude"
strategy = "claude --resume"   # explicit strategy replaces argv

[[restore.command]]
match = "ssh"                  # ssh user@host replayed with original args

[[restore.command]]
match = "less"                 # less myfile.log replayed

[[restore.command]]
match = "htop"                 # bare-named utilities with no args
```

- [ ] **Step 2: Commit**

```bash
git add docs/config-example.toml
git commit -m "docs(config): example [[restore.command]] allowlist"
```

---

## Phase 2 — libghostty patches + foreground process detection

### Task 8: Write `0002-expose-shell-pid.patch`

**Files:**
- Create: `patches/ghostty/0002-expose-shell-pid.patch`

- [ ] **Step 1: Locate the right insertion point in ghostty source**

```bash
cd vendor/ghostty
rg -n "export fn ghostty_surface_process_exited" src/apprt/embedded.zig
```

Expected output: a line number near 1604. We'll add our new export immediately after this function because it's thematically similar ("surface subprocess state").

Also locate the subprocess PID inside `Surface`:

```bash
rg -n "termio|subprocess|backend\.exec" src/apprt/embedded.zig | head -20
```

Confirm the surface's termio pipeline exposes the child PID at
`surface.core_surface.io.backend.exec.command.?.pid`. (If the exact path
differs in the vendored version, adjust the patch below to match.)

- [ ] **Step 2: Write the patch**

Create `patches/ghostty/0002-expose-shell-pid.patch`:

```diff
diff --git a/src/apprt/embedded.zig b/src/apprt/embedded.zig
index 0000000..0000001 100644
--- a/src/apprt/embedded.zig
+++ b/src/apprt/embedded.zig
@@ -1604,6 +1604,28 @@ pub const Surface = struct {
     export fn ghostty_surface_process_exited(surface: *Surface) bool {
         return surface.core_surface.child_exited;
     }
 
+    /// Mistty patch: expose the shell (or user-specified `command`) child
+    /// process PID so the host app can resolve the foreground process on
+    /// the surface's tty via `tcgetpgrp` / `proc_*`. Returns `-1` if the
+    /// child hasn't started yet, has exited, or the termio backend doesn't
+    /// track a PID (e.g. tests).
+    export fn ghostty_surface_command_pid(surface: *Surface) c_int {
+        const core = &surface.core_surface;
+        switch (core.io.backend) {
+            .exec => |*exec| {
+                const cmd = exec.command orelse return -1;
+                return @as(c_int, @intCast(cmd.pid orelse return -1));
+            },
+            else => return -1,
+        }
+    }
+
     export fn ghostty_surface_has_selection(surface: *Surface) bool {
         return surface.core_surface.io.terminal.screens.active.selected();
     }
```

Note that the exact `core.io.backend` field path and `cmd.pid` resolution
may differ between ghostty versions — the next step verifies by applying.

- [ ] **Step 3: Also add the public header declaration**

Append the following hunk to the same patch file (so one patch covers both
the Zig export and the C header):

```diff
diff --git a/include/ghostty.h b/include/ghostty.h
index 0000000..0000002 100644
--- a/include/ghostty.h
+++ b/include/ghostty.h
@@ -1115,6 +1115,9 @@ void ghostty_surface_request_close(ghostty_surface_t);
 void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t);
 #endif
 
+/* Mistty patch: see embedded.zig. */
+int ghostty_surface_command_pid(ghostty_surface_t);
+
 void ghostty_surface_split(ghostty_surface_t, ghostty_action_split_direction_e);
```

- [ ] **Step 4: Commit**

```bash
cd /Users/manu/Developer/mistty/.worktrees/state-restoration  # back out of vendor submodule
git add patches/ghostty/0002-expose-shell-pid.patch
git commit -m "patches(ghostty): expose shell command PID via ghostty_surface_command_pid"
```

---

### Task 9: Write `0003-expose-pty-slave-fd.patch`

**Files:**
- Create: `patches/ghostty/0003-expose-pty-slave-fd.patch`

- [ ] **Step 1: Locate the pty master fd in ghostty source**

```bash
cd vendor/ghostty
rg -n "master|pty|subprocess.*fd" src/termio/Exec.zig | head -20
```

Confirm the exec backend holds the master fd at a path like
`exec.subprocess.pty.master` or `exec.pty.master`. (Adjust the patch
below if the path differs.)

- [ ] **Step 2: Write the patch**

Create `patches/ghostty/0003-expose-pty-slave-fd.patch`:

```diff
diff --git a/src/apprt/embedded.zig b/src/apprt/embedded.zig
index 0000001..0000002 100644
--- a/src/apprt/embedded.zig
+++ b/src/apprt/embedded.zig
@@ -1626,6 +1626,23 @@ pub const Surface = struct {
         return @as(c_int, @intCast(cmd.pid orelse return -1));
     }
 
+    /// Mistty patch: expose the pty master fd for this surface so the host
+    /// app can call `tcgetpgrp(fd)` to find the foreground process group.
+    /// Returns `-1` when the pty hasn't been opened yet or the termio
+    /// backend is something other than `.exec`.
+    export fn ghostty_surface_pty_fd(surface: *Surface) c_int {
+        const core = &surface.core_surface;
+        switch (core.io.backend) {
+            .exec => |*exec| {
+                const master = exec.subprocess.pty.master orelse return -1;
+                return @as(c_int, @intCast(master));
+            },
+            else => return -1,
+        }
+    }
+
     export fn ghostty_surface_has_selection(surface: *Surface) bool {
         return surface.core_surface.io.terminal.screens.active.selected();
     }
diff --git a/include/ghostty.h b/include/ghostty.h
index 0000002..0000003 100644
--- a/include/ghostty.h
+++ b/include/ghostty.h
@@ -1118,6 +1118,9 @@ void ghostty_surface_request_close(ghostty_surface_t);
 /* Mistty patch: see embedded.zig. */
 int ghostty_surface_command_pid(ghostty_surface_t);
 
+/* Mistty patch: see embedded.zig. */
+int ghostty_surface_pty_fd(ghostty_surface_t);
+
 void ghostty_surface_split(ghostty_surface_t, ghostty_action_split_direction_e);
```

- [ ] **Step 3: Commit**

```bash
cd /Users/manu/Developer/mistty/.worktrees/state-restoration
git add patches/ghostty/0003-expose-pty-slave-fd.patch
git commit -m "patches(ghostty): expose pty master fd via ghostty_surface_pty_fd"
```

---

### Task 10: Apply patches and rebuild libghostty; verify symbols

**Files:** (no Swift changes this task)

- [ ] **Step 1: Apply the two new patches**

```bash
just patch-ghostty 2>&1 | tee /tmp/mistty-patch.log
```

Expected: three patches listed as applied (0001, 0002, 0003). If any fail to
apply cleanly, the Zig/C source path or surrounding context has drifted —
adjust the patch's line offsets and retry. Do NOT proceed until the patch
applies cleanly.

- [ ] **Step 2: Rebuild libghostty**

```bash
just build-libghostty 2>&1 | tee /tmp/mistty-libghostty-build.log
```

This can take 5–15 minutes. Wait for it to complete (use `run_in_background`
if driving this step via an agent).

Expected: build succeeds. Any Zig compilation errors usually mean the field
path assumed in the patch doesn't exist — revisit Task 8 / Task 9.

- [ ] **Step 3: Verify the new symbols are exported**

```bash
nm -gU vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a 2>/dev/null | grep -E "ghostty_surface_(command_pid|pty_fd)"
```

Expected: two lines, both prefixed with `T` (or `_`), showing the exported
symbols. If missing, the patch applied but didn't actually add the export —
re-read the `.zig` file directly to confirm.

- [ ] **Step 4: Confirm the Swift bridge picks them up**

```bash
rg -n "ghostty_surface_command_pid|ghostty_surface_pty_fd" vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h
```

Expected: both declarations present in the header.

- [ ] **Step 5: Build the app to confirm nothing regressed**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log
```

Expected: clean build.

- [ ] **Step 6: Commit the rebuilt xcframework**

```bash
git add vendor/ghostty
git commit -m "build(libghostty): apply patches 0002-0003 and rebuild"
```

(If the xcframework is `.gitignore`d in your setup, skip this commit — the
rebuild is a developer-local artifact. Check `git status` first.)

---

### Task 11: Expose `shellPID` + `ptyFD` accessors on `MisttyPane` (TDD)

**Files:**
- Modify: `Mistty/Models/MisttyPane.swift`
- Modify: `Mistty/Views/Terminal/TerminalSurfaceView.swift`

- [ ] **Step 1: Add accessors to `TerminalSurfaceView`**

Open `Mistty/Views/Terminal/TerminalSurfaceView.swift`. Near the top of the
class (after the `surface` property declaration at line 11), add:

```swift
  /// Shell / command child PID from libghostty. `-1` when unavailable.
  var shellPID: pid_t {
    guard let surface else { return -1 }
    let pid = ghostty_surface_command_pid(surface)
    return pid_t(pid)
  }

  /// PTY master fd from libghostty. `-1` when unavailable.
  var ptyFD: Int32 {
    guard let surface else { return -1 }
    return Int32(ghostty_surface_pty_fd(surface))
  }
```

- [ ] **Step 2: Replace `lazy var surfaceView` with explicit backing storage**

Open `Mistty/Models/MisttyPane.swift`. The current `lazy var surfaceView`
doesn't expose whether its backing has been materialized, and the
state-restoration snapshot needs to read `shellPID` / `ptyFD` WITHOUT
allocating a ghostty surface (which would spawn a shell just to answer
"what pid is running here"). Replace the lazy var with an explicit pair:

```swift
  /// Backing storage. `nil` until something calls `surfaceView` for the
  /// first time. Read via `surfaceViewIfLoaded` when you need to peek
  /// without forcing allocation.
  @ObservationIgnored
  private var _surfaceView: TerminalSurfaceView?

  /// The persistent terminal surface view for this pane. Created on first
  /// access so the ghostty surface lives for the lifetime of the pane,
  /// surviving SwiftUI view rebuilds.
  var surfaceView: TerminalSurfaceView {
    if let existing = _surfaceView { return existing }
    let view = TerminalSurfaceView(
      frame: .zero,
      workingDirectory: directory,
      command: useCommandField ? command : nil,
      initialInput: useCommandField ? nil : command,
      waitAfterCommand: waitAfterCommand
    )
    view.pane = self
    _surfaceView = view
    return view
  }

  /// Peek at the surface view without forcing creation. Returns nil if
  /// nothing has called `surfaceView` yet.
  var surfaceViewIfLoaded: TerminalSurfaceView? { _surfaceView }
```

Remove the old `lazy var surfaceView: TerminalSurfaceView = { ... }()`
block at line 46 entirely.

- [ ] **Step 3: Proxy `shellPID` / `ptyFD` on `MisttyPane`**

In the same file, after `processTitle`, add:

```swift
  /// Process ID of the shell (or the command passed via `cfg.command`) that
  /// libghostty spawned for this pane. `-1` when the surface hasn't started
  /// yet, has exited, or libghostty wasn't built with the shell-PID patch.
  /// Reads without forcing surface allocation.
  var shellPID: pid_t {
    surfaceViewIfLoaded?.shellPID ?? -1
  }

  /// Master fd of the pty pair. Use with `tcgetpgrp()` to resolve the
  /// foreground process group on the tty. `-1` when unavailable.
  var ptyFD: Int32 {
    surfaceViewIfLoaded?.ptyFD ?? -1
  }
```

- [ ] **Step 4: Build to confirm wiring compiles**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log
```

Expected: clean build (no tests yet — this is plumbing).

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/MisttyPane.swift Mistty/Views/Terminal/TerminalSurfaceView.swift
git commit -m "feat(pane): expose shellPID and ptyFD via libghostty"
```

---

### Task 12: `ForegroundProcess` struct + resolver protocol seam (TDD)

**Files:**
- Create: `Mistty/Support/ForegroundProcess.swift`
- Create: `MisttyTests/Support/ForegroundProcessResolverTests.swift`

- [ ] **Step 1: Write failing tests for resolver dispatch**

Create `MisttyTests/Support/ForegroundProcessResolverTests.swift`:

```swift
import XCTest
@testable import Mistty

final class ForegroundProcessResolverTests: XCTestCase {
  private final class FakeDescribe {
    var byPID: [pid_t: ForegroundProcess] = [:]
    func describe(pid: pid_t) -> ForegroundProcess? { byPID[pid] }
  }

  func test_primaryPath_returnsPgroupLeaderWhenNotShell() {
    let fake = FakeDescribe()
    fake.byPID[4242] = .init(executable: "nvim", path: "/usr/bin/nvim",
                             argv: ["nvim", "foo"], pid: 4242)
    let probe = ForegroundProcessProbe(
      ptyFD: { 5 },
      shellPID: { 1000 },
      tcgetpgrpOnPTY: { _ in 4242 },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "nvim")
    XCTAssertEqual(result?.argv, ["nvim", "foo"])
  }

  func test_primaryPath_returnsNilWhenShellIsForeground() {
    let probe = ForegroundProcessProbe(
      ptyFD: { 5 },
      shellPID: { 1000 },
      tcgetpgrpOnPTY: { _ in 1000 },  // shell pgroup == shell pid = no fg app
      deepestDescendant: { _ in nil },
      describe: { _ in nil }
    )
    XCTAssertNil(ForegroundProcessResolver.current(via: probe))
  }

  func test_fallbackPath_walksDescendantsWhenPTYUnavailable() {
    let fake = FakeDescribe()
    fake.byPID[7] = .init(executable: "htop", path: "/usr/bin/htop",
                          argv: ["htop"], pid: 7)
    let probe = ForegroundProcessProbe(
      ptyFD: { -1 },                      // no pty fd
      shellPID: { 2 },
      tcgetpgrpOnPTY: { _ in -1 },
      deepestDescendant: { _ in 7 },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "htop")
  }

  func test_fallbackPath_returnsNilWhenNoDescendants() {
    let probe = ForegroundProcessProbe(
      ptyFD: { -1 },
      shellPID: { 2 },
      tcgetpgrpOnPTY: { _ in -1 },
      deepestDescendant: { _ in nil },
      describe: { _ in nil }
    )
    XCTAssertNil(ForegroundProcessResolver.current(via: probe))
  }

  func test_bothPathsFail_returnsNil() {
    let probe = ForegroundProcessProbe(
      ptyFD: { -1 },
      shellPID: { -1 },
      tcgetpgrpOnPTY: { _ in -1 },
      deepestDescendant: { _ in nil },
      describe: { _ in nil }
    )
    XCTAssertNil(ForegroundProcessResolver.current(via: probe))
  }
}
```

- [ ] **Step 2: Run, confirm failure**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
```

Expected: build error — `ForegroundProcessProbe` / `ForegroundProcessResolver`
don't exist yet.

- [ ] **Step 3: Create the module**

Create `Mistty/Support/ForegroundProcess.swift`:

```swift
import Darwin
import Foundation

struct ForegroundProcess: Equatable {
  let executable: String     // basename, e.g. "nvim"
  let path: String           // full path, e.g. "/usr/local/bin/nvim"
  let argv: [String]         // includes argv[0]
  let pid: pid_t
}

/// Injectable probe so tests can drive the resolver without a real pane.
/// Every closure returns `-1` / `nil` for the "unavailable" case.
struct ForegroundProcessProbe {
  var ptyFD: () -> Int32
  var shellPID: () -> pid_t
  var tcgetpgrpOnPTY: (Int32) -> pid_t
  var deepestDescendant: (pid_t) -> pid_t?
  var describe: (pid_t) -> ForegroundProcess?
}

enum ForegroundProcessResolver {
  /// Convenience entrypoint used in production — builds a probe backed by
  /// real syscalls and calls `current(via:)`.
  @MainActor
  static func current(for pane: MisttyPane) -> ForegroundProcess? {
    let probe = ForegroundProcessProbe(
      ptyFD: { pane.ptyFD },
      shellPID: { pane.shellPID },
      tcgetpgrpOnPTY: { fd in tcgetpgrp(fd) },
      deepestDescendant: Self.deepestLiveDescendant(of:),
      describe: Self.describe(pid:)
    )
    return current(via: probe)
  }

  /// Pure dispatch logic; all I/O lives in the probe closures.
  static func current(via probe: ForegroundProcessProbe) -> ForegroundProcess? {
    // Primary: tcgetpgrp on the pty.
    let fd = probe.ptyFD()
    if fd >= 0 {
      let pgid = probe.tcgetpgrpOnPTY(fd)
      if pgid > 0 {
        let shell = probe.shellPID()
        if pgid != shell {
          if let described = probe.describe(pgid) { return described }
        } else {
          // Shell is foreground — no user program running, explicit nil.
          return nil
        }
      }
    }
    // Fallback: deepest descendant of shell PID.
    let shell = probe.shellPID()
    guard shell > 0, let deepest = probe.deepestDescendant(shell), deepest != shell
    else { return nil }
    return probe.describe(deepest)
  }

  // MARK: - Real-syscall helpers

  /// BFS through children of `rootPid`, returning the deepest PID still alive.
  /// Uses `proc_listpids(PROC_PPID_ONLY, parent, …)` to enumerate at each level.
  static func deepestLiveDescendant(of rootPid: pid_t) -> pid_t? {
    var deepest: pid_t? = nil
    var frontier = [rootPid]
    while !frontier.isEmpty {
      var next: [pid_t] = []
      for parent in frontier {
        let children = Self.childrenOf(parent)
        next.append(contentsOf: children)
      }
      if let last = next.last { deepest = last }
      frontier = next
    }
    return deepest
  }

  private static func childrenOf(_ parent: pid_t) -> [pid_t] {
    // proc_listpids signature: (type, typeinfo, buffer, buffersize)
    let count = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
    guard count > 0 else { return [] }
    let bufSize = Int(count) * MemoryLayout<pid_t>.stride
    var buf = [pid_t](repeating: 0, count: Int(count))
    let actual = buf.withUnsafeMutableBufferPointer { ptr in
      proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), ptr.baseAddress, Int32(bufSize))
    }
    guard actual > 0 else { return [] }
    let n = Int(actual) / MemoryLayout<pid_t>.stride
    return Array(buf.prefix(n).filter { $0 > 0 })
  }

  /// Resolve `pid` to a full `ForegroundProcess` via `proc_pidpath` +
  /// `KERN_PROCARGS2`. Returns nil if either call fails.
  static func describe(pid: pid_t) -> ForegroundProcess? {
    var pathBuf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
    let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
    guard n > 0 else { return nil }
    let path = String(cString: pathBuf)
    let executable = (path as NSString).lastPathComponent
    let argv = Self.readArgv(pid: pid) ?? [executable]
    return ForegroundProcess(executable: executable, path: path, argv: argv, pid: pid)
  }

  /// Read argv via `sysctl [CTL_KERN, KERN_PROCARGS2, pid]`. Layout:
  /// `int argc` (aligned), `argv[0]`, `argv[1]`, ..., `env[0]`, ...,
  /// all nul-terminated. We return only the first `argc` strings after the
  /// int header. Falls back to nil on malformed buffer.
  static func readArgv(pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    // First pass: size
    if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size < MemoryLayout<Int32>.size {
      return nil
    }
    var buf = [UInt8](repeating: 0, count: size)
    if sysctl(&mib, 3, &buf, &size, nil, 0) != 0 { return nil }
    return buf.withUnsafeBufferPointer { ptr in
      let base = ptr.baseAddress!
      let argc = base.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
      var offset = MemoryLayout<Int32>.size
      // Skip argv[0]'s leading nulls (executable path echoed before argv).
      while offset < size && base[offset] == 0 { offset += 1 }
      // Skip the executable path (one nul-terminated string).
      while offset < size && base[offset] != 0 { offset += 1 }
      offset += 1  // past the nul
      var result: [String] = []
      var remaining = Int(argc)
      while remaining > 0 && offset < size {
        let start = offset
        while offset < size && base[offset] != 0 { offset += 1 }
        if offset >= size { return nil }
        let bytes = Array(ptr[start..<offset])
        let s = String(bytes: bytes, encoding: .utf8) ?? ""
        result.append(s)
        offset += 1
        remaining -= 1
      }
      return result.isEmpty ? nil : result
    }
  }
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "(ForegroundProcessResolverTests|failed:)" /tmp/mistty-test.log
```

Expected: all 5 resolver-dispatch tests green. Real-syscall helpers
(`deepestLiveDescendant`, `describe`, `readArgv`) are not covered by
these unit tests — they're exercised via the manual test in Phase 4.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Support/ForegroundProcess.swift MisttyTests/Support/ForegroundProcessResolverTests.swift
git commit -m "feat(support): ForegroundProcessResolver with injectable probe"
```

---

### Task 13: Wire `CapturedProcess` into `takeSnapshot()` (no new tests)

**Files:**
- Modify: `Mistty/Models/SessionStore+Snapshot.swift`

- [ ] **Step 1: Replace the placeholder nil with a real capture call**

Open `Mistty/Models/SessionStore+Snapshot.swift`. Find the `snapshotLayout`
helper from Task 5. Replace the `.leaf(let pane)` case:

```swift
    case .leaf(let pane):
      let captured = ForegroundProcessResolver.current(for: pane).map {
        CapturedProcess(executable: $0.executable, argv: $0.argv)
      }
      return .leaf(pane: PaneSnapshot(
        id: pane.id,
        directory: pane.directory,
        currentWorkingDirectory: pane.currentWorkingDirectory,
        captured: captured
      ))
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log
```

Expected: clean build.

- [ ] **Step 3: Run tests, confirm no regressions**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "(failed:|passed)" /tmp/mistty-test.log | tail -20
```

Expected: all previously-green tests remain green. In the unit-test
environment `ptyFD` / `shellPID` return `-1` (no surface view), so
`captured` is always `nil` — no new behavior needed in the tests.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Models/SessionStore+Snapshot.swift
git commit -m "feat(snapshot): capture foreground process into PaneSnapshot"
```

---

## Phase 3 — AppKit state-restoration interop spike

Diagnostic phase. Verifies SwiftUI + NSApplicationDelegate ordering before
committing to the restore wiring. Merge this phase's commit(s) once ordering
is confirmed.

### Task 14: Minimal `AppDelegate` with logging-only hooks

**Files:**
- Create: `Mistty/App/AppDelegate.swift`
- Modify: `Mistty/App/MisttyApp.swift`

- [ ] **Step 1: Create logging-only delegate**

Create `Mistty/App/AppDelegate.swift`:

```swift
import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
    DebugLog.shared.log("restore", "willEncodeRestorableState fired")
  }

  func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
    DebugLog.shared.log("restore", "didDecodeRestorableState fired")
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    DebugLog.shared.log("restore", "applicationWillFinishLaunching")
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    DebugLog.shared.log("restore", "applicationDidFinishLaunching")
  }
}
```

- [ ] **Step 2: Wire via `@NSApplicationDelegateAdaptor`**

Open `Mistty/App/MisttyApp.swift`. Near the top of `struct MisttyApp`:

```swift
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
```

Add this as the first property in the struct (before `@State private var store`).

Also add a DebugLog call to `init()` so the ordering log is interleaved:

```swift
  init() {
    DebugLog.shared.log("restore", "MisttyApp.init")
    _ = GhosttyAppManager.shared
    Self.registerBundledFonts()
    DebugLog.shared.configure(enabled: config.debugLogging)
  }
```

- [ ] **Step 3: Enable debug logging if not already**

Ensure your `~/.config/mistty/config.toml` has:

```toml
debug_logging = true
```

- [ ] **Step 4: Build, run, quit, relaunch, inspect log**

```bash
just bundle 2>&1 | tee /tmp/mistty-bundle.log
open build/Mistty-dev.app
# Open a session, make some splits, then quit (cmd-q)
# Relaunch:
open build/Mistty-dev.app
# Quit again
cat ~/Library/Logs/Mistty/mistty-debug.log | tail -40
```

Expected order on the second launch:

```
[restore] MisttyApp.init
[restore] applicationWillFinishLaunching
[restore] didDecodeRestorableState fired   ← before SwiftUI shows a window
[restore] applicationDidFinishLaunching
```

If `didDecodeRestorableState` fires *after* `applicationDidFinishLaunching`
(or after SwiftUI has visibly spawned a window), flag this in the commit
message — Task 17 will need the `.restorationBehavior(.disabled)` + gated
`onAppear` fallback. If the order matches expectation, proceed as planned.

- [ ] **Step 5: Commit**

```bash
git add Mistty/App/AppDelegate.swift Mistty/App/MisttyApp.swift
git commit -m "feat(app): logging-only AppDelegate for state-restoration ordering spike"
```

Attach the observed log excerpt to the commit body (or next commit) so future
reviewers can verify the ordering assumption.

---

## Phase 4 — Full restore wiring

### Task 15: Populate AppDelegate encode/decode with real snapshot JSON

**Files:**
- Modify: `Mistty/App/AppDelegate.swift`

- [ ] **Step 1: Replace logging-only hooks with serialization**

Open `Mistty/App/AppDelegate.swift`. Replace the class body with:

```swift
import AppKit
import Foundation
import MisttyShared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Set by `MisttyApp.init()` right after the adaptor materializes us.
  var store: SessionStore!

  /// Strong ref so the observer outlives init. Set by `MisttyApp.init()`.
  var observer: StateRestorationObserver?

  private static let coderKey = "workspace"

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
    guard let store else { return }
    let snapshot = store.takeSnapshot()
    do {
      let data = try JSONEncoder().encode(snapshot)
      coder.encode(data as NSData, forKey: Self.coderKey)
      DebugLog.shared.log(
        "restore",
        "encoded snapshot: \(snapshot.sessions.count) sessions, \(data.count) bytes")
    } catch {
      DebugLog.shared.log("restore", "encode failed: \(error)")
    }
  }

  func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
    guard let store else { return }
    guard let data = coder.decodeObject(of: NSData.self, forKey: Self.coderKey) as Data?
    else {
      DebugLog.shared.log("restore", "no workspace data in coder")
      return
    }
    do {
      let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
      if let bad = snapshot.unsupportedVersion {
        DebugLog.shared.log("restore", "unsupported version \(bad); starting empty")
        return
      }
      let config = MisttyConfig.loadedAtLaunch.config.restore
      store.restore(from: snapshot, config: config)
      DebugLog.shared.log(
        "restore",
        "decoded snapshot: restored \(snapshot.sessions.count) sessions")
    } catch {
      DebugLog.shared.log("restore", "decode failed: \(error)")
    }
  }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log
```

Expected: clean build (observer is still a forward declaration; we add it
next task).

- [ ] **Step 3: Commit**

```bash
git add Mistty/App/AppDelegate.swift
git commit -m "feat(app): encode/decode WorkspaceSnapshot via AppDelegate"
```

---

### Task 16: Implement `StateRestorationObserver`

**Files:**
- Create: `Mistty/Services/StateRestorationObserver.swift`

- [ ] **Step 1: Create the observer**

Create `Mistty/Services/StateRestorationObserver.swift`:

```swift
import AppKit
import Foundation

@MainActor
final class StateRestorationObserver {
  let store: SessionStore

  init(store: SessionStore) {
    self.store = store
    reobserve()
  }

  private func reobserve() {
    withObservationTracking {
      _ = snapshotKeys()
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        NSApp?.invalidateRestorableState()
        self?.reobserve()
      }
    }
  }

  /// Touches every observable field that flows into `WorkspaceSnapshot`.
  /// `@Observable` tracks each read; any mutation causes `reobserve` to
  /// re-fire and post the invalidation.
  private func snapshotKeys() -> Int {
    var h = 0
    h ^= store.sessions.count
    if let active = store.activeSession { h ^= active.id }
    for session in store.sessions {
      h ^= session.id ^ session.name.hashValue
      h ^= session.customName?.hashValue ?? 0
      h ^= session.sshCommand?.hashValue ?? 0
      h ^= session.lastActivatedAt.hashValue
      h ^= session.tabs.count
      if let activeTab = session.activeTab { h ^= activeTab.id }
      for tab in session.tabs {
        h ^= tab.id ^ (tab.customTitle?.hashValue ?? 0)
        if let activePane = tab.activePane { h ^= activePane.id }
        for pane in tab.panes {
          h ^= pane.id
          h ^= pane.directory?.absoluteString.hashValue ?? 0
          h ^= pane.currentWorkingDirectory?.absoluteString.hashValue ?? 0
        }
        // Observe the layout tree's identity. The leaves we already visited;
        // ratios live only in splits, so sample the root's immediate ratio.
        if case .split(_, _, _, let ratio) = tab.layout.root {
          h ^= Int(ratio * 1000)
        }
      }
    }
    return h
  }
}
```

- [ ] **Step 2: Wire into MisttyApp.init**

Open `Mistty/App/MisttyApp.swift`. Expand `init()`:

```swift
  init() {
    DebugLog.shared.log("restore", "MisttyApp.init")
    _ = GhosttyAppManager.shared
    Self.registerBundledFonts()
    DebugLog.shared.configure(enabled: config.debugLogging)
    appDelegate.store = store
    appDelegate.observer = StateRestorationObserver(store: store)
  }
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Services/StateRestorationObserver.swift Mistty/App/MisttyApp.swift
git commit -m "feat(app): StateRestorationObserver + MisttyApp wiring"
```

---

### Task 17: (Conditional) SwiftUI restoration-behavior fallback

Only do this task if the Task 14 spike showed that `didDecodeRestorableState`
fires AFTER SwiftUI creates its window. If the ordering was safe, skip to
Task 18.

**Files:**
- Modify: `Mistty/Models/SessionStore.swift`
- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Add a `didRestore` flag to SessionStore**

In `SessionStore`, add:

```swift
  /// True once `restore(from:config:)` has returned, even if it restored nothing.
  /// ContentView's first render gates on this to avoid flashing an empty state.
  var didRestore: Bool = false
```

In `SessionStore+Snapshot.swift`, at the top of `restore(from:config:)`:

```swift
  defer { didRestore = true }
```

Also mark `didRestore = true` from `AppDelegate` when the coder has no
workspace data (so cold-start paths also unblock):

```swift
  // In `didDecodeRestorableState`, after the `guard let data` early return:
  //   store.didRestore = true  // falls through to cold start
```

- [ ] **Step 2: Disable SwiftUI scene restoration**

In `MisttyApp.body`:

```swift
    WindowGroup {
      ContentView(store: store, config: config)
        // ... existing modifiers
    }
    .windowStyle(.hiddenTitleBar)
    .restorationBehavior(.disabled)   // AppKit drives restore, not SwiftUI
```

- [ ] **Step 3: Gate `ContentView` body on `didRestore`**

Wrap the top-level content in `ContentView.body`:

```swift
  var body: some View {
    Group {
      if store.didRestore {
        // existing body contents
      } else {
        Color(NSColor.windowBackgroundColor)
          .ignoresSafeArea()
      }
    }
  }
```

Also set `store.didRestore = true` from an `.onAppear` after a single
runloop tick, so cold starts without AppKit restoration still unblock:

```swift
    .onAppear {
      DispatchQueue.main.async { store.didRestore = true }
    }
```

- [ ] **Step 4: Build + manual verify**

```bash
swift build && just bundle
open build/Mistty-dev.app
```

Quit, relaunch, verify there's no flash of empty state.

- [ ] **Step 5: Commit (if applied)**

```bash
git add Mistty/Models/SessionStore.swift Mistty/App/MisttyApp.swift Mistty/App/ContentView.swift
git commit -m "feat(app): gate ContentView on didRestore to avoid empty-state flash"
```

---

### Task 18: End-to-end manual verification

**Files:** (none — manual testing)

- [ ] **Step 1: Rebuild the dev bundle**

```bash
just bundle 2>&1 | tee /tmp/mistty-bundle.log
```

- [ ] **Step 2: Exercise every acceptance criterion manually**

For each criterion in `docs/superpowers/specs/2026-04-22-state-restoration-design.md` §"Acceptance criteria":

1. **AC1 — structural round-trip**: Launch Mistty. Open 2 sessions. In one,
   create a second tab with 2 vertical splits. In the other, create a
   horizontal split. Quit (cmd-q). Relaunch. Confirm layouts, tab order,
   session order match.

2. **AC2 — CWD restoration**: In one pane `cd /tmp/some-subdir`. Quit.
   Relaunch. Confirm that pane's prompt is at `/tmp/some-subdir`.

3. **AC3 — custom names**: Rename a tab (`cmd+shift+r`) to "REPL". Quit.
   Relaunch. Tab is still "REPL".

4. **AC4 — active markers**: Have session A active; in A, tab 2 is active;
   in that tab, the right split is active. Quit. Relaunch. Cursor focus
   and highlighting are on the same session/tab/pane.

5. **AC5 — nvim replay**: Add `[[restore.command]] match = "nvim"` to
   `config.toml`. In a pane, run `nvim /tmp/foo.txt`. Quit. Relaunch.
   Confirm the pane reopens `nvim /tmp/foo.txt`.

6. **AC6 — claude strategy**: Add `[[restore.command]] match = "claude"
   strategy = "claude --resume"`. In a pane, run `claude`. Quit. Relaunch.
   Confirm the pane runs `claude --resume`.

7. **AC7 — non-allowlisted**: In a pane, run `htop` (no allowlist entry).
   Quit. Relaunch. Pane is at a bare shell in the same CWD; no relaunch.

8. **AC8 — SSH replay**: Add `[[restore.command]] match = "ssh"`. Open an
   SSH session. Quit. Relaunch. Pane runs ssh again.

9. **AC9 — Option-Quit clears state**: With a non-trivial workspace, hold
   Option and click Quit (or press Option-Cmd-Q). Relaunch. Empty workspace.

10. **AC10 — System Setting honored**: System Settings → General → "Close
    windows when quitting an app" = on. Quit Mistty normally. Relaunch.
    Empty workspace.

11. **AC11 — CLI debug dump** (requires Task 20): skip for now.

12. **AC12 — sudden termination**: Open a session, make a structural change,
    `kill -9` the Mistty process. Relaunch. Expect the change to persist
    (AppKit's autosave should have fired within the coalesce window).

Document any criterion that fails in a new note and iterate before Phase 5.

- [ ] **Step 3: If all pass, commit a one-liner**

```bash
git commit --allow-empty -m "test(restore): manual acceptance pass 1-10,12"
```

---

## Phase 5 — Debug CLI affordance

### Task 19: Add `getStateSnapshot` IPC endpoint

**Files:**
- Modify: `MisttyShared/MisttyServiceProtocol.swift`
- Modify: `Mistty/Services/IPCService.swift`
- Modify: `Mistty/Services/IPCListener.swift`

- [ ] **Step 1: Declare the RPC on the protocol**

Open `MisttyShared/MisttyServiceProtocol.swift`. Add a method:

```swift
  func getStateSnapshot() -> String
```

(Returns a pretty-printed JSON string so the CLI doesn't need to re-encode.
If the protocol uses a different style, follow the existing pattern.)

- [ ] **Step 2: Implement on `IPCService`**

Open `Mistty/Services/IPCService.swift`. Add:

```swift
  func getStateSnapshot() -> String {
    let snapshot = store.takeSnapshot()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      let data = try encoder.encode(snapshot)
      return String(data: data, encoding: .utf8) ?? "{}"
    } catch {
      return "{\"error\": \"\(error.localizedDescription)\"}"
    }
  }
```

- [ ] **Step 3: Route in `IPCListener`**

Open `Mistty/Services/IPCListener.swift`. Find the existing method dispatch
switch (around `case "createSession"`). Add a new case:

```swift
    case "getStateSnapshot":
      let json = service.getStateSnapshot()
      respond(["snapshot": json])
```

Adapt `respond(...)` to whatever helper the listener uses.

- [ ] **Step 4: Build + verify binding via a dummy call**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log
```

Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add MisttyShared/MisttyServiceProtocol.swift Mistty/Services/IPCService.swift Mistty/Services/IPCListener.swift
git commit -m "feat(ipc): getStateSnapshot RPC"
```

---

### Task 20: `mistty-cli debug state` subcommand

**Files:**
- Create: `MisttyCLI/Commands/DebugCommand.swift`
- Modify: `MisttyCLI/MisttyCLI.swift`

- [ ] **Step 1: Create the subcommand**

Create `MisttyCLI/Commands/DebugCommand.swift`:

```swift
import ArgumentParser
import Foundation
import MisttyShared

struct DebugCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "debug",
    abstract: "Developer diagnostics.",
    subcommands: [StateCommand.self]
  )

  struct StateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "state",
      abstract: "Print the live WorkspaceSnapshot as JSON."
    )

    func run() throws {
      let client = IPCClient()
      let response = try client.request(method: "getStateSnapshot", params: [:])
      if let json = response["snapshot"] as? String {
        print(json)
      } else {
        FileHandle.standardError.write(Data("No snapshot field in response\n".utf8))
        throw ExitCode.failure
      }
    }
  }
}
```

- [ ] **Step 2: Register the command**

Open `MisttyCLI/MisttyCLI.swift`. Find the root command's `subcommands`
array (near `SessionCommand.self`, `TabCommand.self`, etc.). Append:

```swift
      DebugCommand.self,
```

- [ ] **Step 3: Build the CLI**

```bash
swift build 2>&1 | tee /tmp/mistty-build.log
```

Expected: clean build.

- [ ] **Step 4: Manual verification**

With Mistty running, open a pane with several tabs/splits:

```bash
# In the pane:
mistty-cli debug state | jq .
```

Expected: pretty-printed JSON matching `WorkspaceSnapshot` structure — a
`version`, `sessions` array, and `activeSessionID`.

Pipe through `jq '.sessions | length'` to verify it matches the number of
open sessions.

- [ ] **Step 5: Commit**

```bash
git add MisttyCLI/Commands/DebugCommand.swift MisttyCLI/MisttyCLI.swift
git commit -m "feat(cli): mistty-cli debug state"
```

---

### Task 21: Final acceptance sweep + PLAN update

**Files:**
- Modify: `PLAN.md`

- [ ] **Step 1: Run AC11 (now that the CLI exists)**

Rebuild the bundle, launch, open a non-trivial workspace, run
`mistty-cli debug state | jq .` and confirm the output matches the live
app state.

- [ ] **Step 2: Move the `Save layouts` entry in PLAN.md**

Open `PLAN.md`. Move the `Save layouts` section out of `## TODO` and into
`## Implemented`. Reference the spec + plan files and keep the v2+
followups bullet list intact.

Paste into `## Implemented` just before the `Bug fixes` subsection:

```markdown
### State restoration

- Auto-save / auto-restore workspace (sessions/tabs/panes/layouts/CWDs) via
  AppKit state restoration (`applicationSupportsSecureRestorableState`). Spec:
  `docs/superpowers/specs/2026-04-22-state-restoration-design.md`; plan:
  `docs/superpowers/plans/2026-04-22-state-restoration.md`.
- `[[restore.command]]` allowlist with optional `strategy` override for
  per-executable relaunch behavior (nvim/vim/claude/ssh/less/htop examples
  in `docs/config-example.toml`).
- Foreground process detection via `tcgetpgrp(pty_fd)` (primary) with
  shell-PID descendant walk fallback. Two libghostty patches:
  `0002-expose-shell-pid`, `0003-expose-pty-slave-fd`.
- `mistty-cli debug state` dumps the live WorkspaceSnapshot as JSON.
- Hold Option on Quit clears state; System Settings → "Close windows when
  quitting an app" is honored (native AppKit behavior).
```

Delete the `### Save layouts` block from `## TODO`.

- [ ] **Step 3: Commit**

```bash
git add PLAN.md
git commit -m "docs(plan): mark state restoration shipped"
```

- [ ] **Step 4: Final format + test sweep**

```bash
just fmt
just test 2>&1 | tee /tmp/mistty-test-final.log
grep -E "failed:" /tmp/mistty-test-final.log
```

Expected: no failures; no unexpected format diffs.

- [ ] **Step 5: Push branch**

```bash
git push -u origin feat/state-restoration
```

Then open a PR back into main.

---

## Appendix — Test matrix recap

| Test file | Concern | Task(s) |
| --- | --- | --- |
| `MisttyTests/Config/RestoreConfigTests.swift` | Rule parsing, argv shell-joining, first-match-wins | 1, 2 |
| `MisttyTests/Config/MisttyConfigTests.swift` | `[[restore.command]]` parse + save round-trip | 2 |
| `MisttyTests/Snapshot/WorkspaceSnapshotTests.swift` | DTO JSON round-trip, version rejection | 3, 4 |
| `MisttyTests/Snapshot/SessionStoreSnapshotTests.swift` | take/restore semantics, ID counter advance, missing-dir fallback | 5, 6 |
| `MisttyTests/Support/ForegroundProcessResolverTests.swift` | Primary→fallback dispatch via injected probe | 12 |

Manual verification covers: libghostty patch symbols (Task 10),
AppKit ordering spike (Task 14), end-to-end quit/relaunch flows
(Task 18, Task 21).
