# Per-Process Clipboard-Read Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the coarse global `allow_clipboard_read` bool with a per-process OSC-52 clipboard-read permission system: global mode `allow | prompt | deny` (default `prompt`), persisted per-process overrides, in-memory session overrides, and an interactive sheet prompt.

**Architecture:** A pure decision core (`ClipboardPermission.resolve`) computes precedence (session → per-process → global); a `@MainActor ClipboardPermissionCoordinator` holds session overrides, resolves the requesting pane's foreground executable, presents an `NSAlert` sheet on the pane's window when the mode is `prompt`, and persists "always" choices to config. The libghostty `confirm_read_clipboard_cb` routes OSC-52 reads through the coordinator. Spec: `docs/superpowers/specs/2026-06-13-clipboard-read-permissions-design.md`.

**Tech Stack:** Swift / SwiftPM, XCTest, TOMLKit, libghostty (GhosttyKit). AppKit `NSAlert.beginSheetModal`.

**Verification commands:**
- Filtered: `swift test --skip Benchmark --filter <ClassName> 2>&1 | tee /tmp/clip-test.log`
- Full: `swift test --skip Benchmark 2>&1 | tee /tmp/clip-test.log` — **23 `ChromePolishSnapshotTests` failures are the known baseline; any other failure is a regression.**
- Build: `swift build 2>&1 | tee /tmp/clip-build.log`

**Background — current state (to be changed):**
- `Mistty/Config/MisttyConfig.swift:213` `var allowClipboardRead: Bool = false`; parsed at `:260`; saved at `:513`.
- `Mistty/App/GhosttyApp.swift:~203` the OSC-52 branch of `confirmReadClipboardCallback` reads `MisttyConfig.current.allowClipboardRead`.
- `MisttyTests/Config/MisttyConfigTests.swift:349` `test_allowClipboardRead_defaultsFalse_parsesAndRoundTrips` — replaced in Task 1.
- Precedent for per-process config: `SSHHostOverride`/`SSHConfig` (`MisttyConfig.swift:7-31`), parsed from `[[ssh.host]]` (`:287`), saved (`:537`).
- libghostty `clipboard-read` defaults to `ask`, so `confirm_read_clipboard_cb` is already invoked for OSC-52 reads (the existing deny works) — **no GhosttyConfig change needed.**

---

### Task 1: `ClipboardReadMode` + global mode (replace the bool)

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift` (add enum + field; replace parse + save; remove `allowClipboardRead`)
- Modify: `MisttyTests/Config/MisttyConfigTests.swift` (replace the old bool test)

- [ ] **Step 1: Write the failing tests**

In `MisttyTests/Config/MisttyConfigTests.swift`, replace the whole `test_allowClipboardRead_defaultsFalse_parsesAndRoundTrips` function with:

```swift
  func test_clipboardRead_defaultsToPrompt() {
    XCTAssertEqual(MisttyConfig().clipboardRead, .prompt)
  }

  func test_clipboardRead_parsesModeStrings() throws {
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = \"allow\"").clipboardRead, .allow)
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = \"prompt\"").clipboardRead, .prompt)
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = \"deny\"").clipboardRead, .deny)
  }

  func test_clipboardRead_migratesLegacyBool() throws {
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = true").clipboardRead, .allow)
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = false").clipboardRead, .deny)
  }

  func test_clipboardRead_unrecognizedFallsBackToPrompt() throws {
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = \"bogus\"").clipboardRead, .prompt)
  }

  func test_clipboardRead_roundTrips() throws {
    for mode in [ClipboardReadMode.allow, .deny] {  // .prompt is the default → not emitted
      var config = MisttyConfig()
      config.clipboardRead = mode
      let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mistty-clipmode-\(UUID().uuidString).toml")
      defer { try? FileManager.default.removeItem(at: tmp) }
      try config.save(to: tmp)
      XCTAssertEqual(try MisttyConfig.loadThrowing(from: tmp).clipboardRead, mode)
    }
  }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --skip Benchmark --filter MisttyConfigTests 2>&1 | tee /tmp/clip-test.log`
Expected: compile FAILURE — `cannot find type 'ClipboardReadMode'` / `value of type 'MisttyConfig' has no member 'clipboardRead'`.

- [ ] **Step 3: Add the enum**

In `Mistty/Config/MisttyConfig.swift`, immediately before `struct SSHHostOverride` (line 7), add:

```swift
/// How OSC-52 clipboard *reads* from a program in a pane are handled. Cmd+V
/// paste is always allowed and unaffected by this.
enum ClipboardReadMode: String, Sendable, Equatable {
  case allow
  case prompt
  case deny
}
```

- [ ] **Step 4: Replace the field**

Replace `var allowClipboardRead: Bool = false` (line ~213, keep the surrounding doc comment but update it) with:

```swift
  /// Global policy for program-initiated OSC-52 clipboard *reads*. `prompt`
  /// (default) asks per requesting process; `allow`/`deny` decide silently.
  /// Per-process rules (`clipboardProcessRules`) and in-memory session
  /// overrides take precedence. Does NOT affect Cmd+V paste.
  var clipboardRead: ClipboardReadMode = .prompt
```

- [ ] **Step 5: Replace the parse**

Replace the parse line (line ~260)
`if let allow = table["allow_clipboard_read"]?.bool { config.allowClipboardRead = allow }`
with:

```swift
    // Prefer the mode string; tolerate the legacy bool (true→allow, false→deny);
    // unrecognized values keep the .prompt default.
    if let mode = table["allow_clipboard_read"]?.string {
      config.clipboardRead = ClipboardReadMode(rawValue: mode) ?? .prompt
    } else if let legacy = table["allow_clipboard_read"]?.bool {
      config.clipboardRead = legacy ? .allow : .deny
    }
```

- [ ] **Step 6: Replace the save**

Replace the save block (line ~513)
```swift
    if allowClipboardRead {
      lines.append("allow_clipboard_read = true")
    }
```
with:

```swift
    if clipboardRead != MisttyConfig().clipboardRead {
      lines.append("allow_clipboard_read = \"\(clipboardRead.rawValue)\"")
    }
```

- [ ] **Step 7: Update the GhosttyApp call site so the project still builds**

In `Mistty/App/GhosttyApp.swift`, the OSC-52 `default:` branch currently reads `MisttyConfig.current.allowClipboardRead`. Temporarily change it to keep building (Task 6 rewrites it fully):

```swift
  default:
    // Temporary: full per-process routing lands in Task 6.
    if MisttyConfig.current.clipboardRead == .allow {
      ghostty_surface_complete_clipboard_request(surface, str, state, true)
    } else {
      ghostty_surface_complete_clipboard_request(surface, "", state, true)
    }
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift build 2>&1 | tee /tmp/clip-build.log && swift test --skip Benchmark --filter MisttyConfigTests 2>&1 | tee /tmp/clip-test.log`
Expected: build PASS; all MisttyConfigTests PASS.

- [ ] **Step 9: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift Mistty/App/GhosttyApp.swift MisttyTests/Config/MisttyConfigTests.swift
git commit -m "feat(config): clipboard read tri-state mode (allow/prompt/deny)

Replaces the allow_clipboard_read bool with a ClipboardReadMode enum,
default prompt. Parses the mode string, migrates the legacy bool
(true->allow, false->deny), round-trips on save.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Per-process rules (`ClipboardProcessRule`)

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift` (struct + field + parse + save + lookup + upsert helper)
- Modify: `MisttyTests/Config/MisttyConfigTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `MisttyTests/Config/MisttyConfigTests.swift`:

```swift
  func test_clipboardProcessRules_parse() throws {
    let toml = """
      [[clipboard.process]]
      name = "nvim"
      allow_clipboard_read = "allow"

      [[clipboard.process]]
      name = "sketchytui"
      allow_clipboard_read = "deny"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.clipboardProcessRules, [
      .init(name: "nvim", mode: .allow),
      .init(name: "sketchytui", mode: .deny),
    ])
  }

  func test_clipboardProcessRules_skipInvalidEntries() throws {
    let toml = """
      [[clipboard.process]]
      allow_clipboard_read = "allow"

      [[clipboard.process]]
      name = "x"
      allow_clipboard_read = "bogus"

      [[clipboard.process]]
      name = "nvim"
      allow_clipboard_read = "prompt"
      """
    // First missing name → skipped; second bad mode → skipped; third kept.
    XCTAssertEqual(try MisttyConfig.parse(toml).clipboardProcessRules,
                   [.init(name: "nvim", mode: .prompt)])
  }

  func test_clipboardProcessRule_lookup_firstMatchWins() {
    var config = MisttyConfig()
    config.clipboardProcessRules = [
      .init(name: "nvim", mode: .allow),
      .init(name: "nvim", mode: .deny),
    ]
    XCTAssertEqual(config.clipboardProcessRule(for: "nvim"), .allow)
    XCTAssertNil(config.clipboardProcessRule(for: "zsh"))
  }

  func test_settingClipboardProcessRule_upserts() {
    let base = MisttyConfig()
    let added = base.settingClipboardProcessRule(name: "nvim", mode: .allow)
    XCTAssertEqual(added.clipboardProcessRules, [.init(name: "nvim", mode: .allow)])
    let replaced = added.settingClipboardProcessRule(name: "nvim", mode: .deny)
    XCTAssertEqual(replaced.clipboardProcessRules, [.init(name: "nvim", mode: .deny)])
  }

  func test_clipboardProcessRules_roundTrip() throws {
    var config = MisttyConfig()
    config.clipboardProcessRules = [
      .init(name: "nvim", mode: .allow),
      .init(name: "sketchytui", mode: .deny),
    ]
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-cliprules-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    XCTAssertEqual(try MisttyConfig.loadThrowing(from: tmp).clipboardProcessRules,
                   config.clipboardProcessRules)
  }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --skip Benchmark --filter MisttyConfigTests 2>&1 | tee /tmp/clip-test.log`
Expected: compile FAILURE — `cannot find type 'ClipboardProcessRule'` etc.

- [ ] **Step 3: Add the struct + field**

In `Mistty/Config/MisttyConfig.swift`, after the `ClipboardReadMode` enum from Task 1, add:

```swift
/// A per-process override for OSC-52 clipboard reads, keyed on the local
/// foreground executable basename (e.g. "nvim"). Mirrors `SSHHostOverride`.
struct ClipboardProcessRule: Sendable, Equatable {
  var name: String
  var mode: ClipboardReadMode
}
```

In the `MisttyConfig` struct, directly after the `clipboardRead` field, add:

```swift
  /// Per-process OSC-52 read overrides, first exact-name match wins. Written
  /// by the permission prompt's "always" choices; hand-editable.
  var clipboardProcessRules: [ClipboardProcessRule] = []
```

- [ ] **Step 4: Add lookup + upsert helpers**

In the `MisttyConfig` struct body (near other helpers), add:

```swift
  /// The per-process rule mode for `executable`, or nil if none matches.
  /// First exact-name match wins (mirrors `SSHConfig.resolveCommand`).
  func clipboardProcessRule(for executable: String) -> ClipboardReadMode? {
    clipboardProcessRules.first { $0.name == executable }?.mode
  }

  /// A copy with the rule for `name` upserted (replace existing by name,
  /// else append). Used to persist an "always" prompt choice.
  func settingClipboardProcessRule(name: String, mode: ClipboardReadMode) -> MisttyConfig {
    var copy = self
    if let idx = copy.clipboardProcessRules.firstIndex(where: { $0.name == name }) {
      copy.clipboardProcessRules[idx].mode = mode
    } else {
      copy.clipboardProcessRules.append(ClipboardProcessRule(name: name, mode: mode))
    }
    return copy
  }
```

- [ ] **Step 5: Parse `[[clipboard.process]]`**

In `parse`, after the `if let copyMode = table["copy_mode"]?.table { ... }` block (i.e. alongside the other section parsers), add:

```swift
    if let clipboard = table["clipboard"]?.table,
      let processArray = clipboard["process"]?.array
    {
      config.clipboardProcessRules = processArray.compactMap { entry -> ClipboardProcessRule? in
        guard let t = entry.table,
          let name = t["name"]?.string,
          let modeStr = t["allow_clipboard_read"]?.string,
          let mode = ClipboardReadMode(rawValue: modeStr)
        else { return nil }
        return ClipboardProcessRule(name: name, mode: mode)
      }
    }
```

- [ ] **Step 6: Save `[[clipboard.process]]`**

In `save`, after the SSH block (the `if ssh.defaultCommand != "ssh" || !ssh.hosts.isEmpty { ... }` block ending around line 547), add:

```swift
    if !clipboardProcessRules.isEmpty {
      for rule in clipboardProcessRules {
        lines.append("")
        lines.append("[[clipboard.process]]")
        lines.append("name = \"\(tomlEscape(rule.name))\"")
        lines.append("allow_clipboard_read = \"\(rule.mode.rawValue)\"")
      }
    }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --skip Benchmark --filter MisttyConfigTests 2>&1 | tee /tmp/clip-test.log`
Expected: all MisttyConfigTests PASS.

- [ ] **Step 8: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift MisttyTests/Config/MisttyConfigTests.swift
git commit -m "feat(config): per-process clipboard read rules ([[clipboard.process]])

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Pure decision core (`ClipboardPermission`)

**Files:**
- Create: `Mistty/Models/ClipboardPermission.swift`
- Test: Create `MisttyTests/Models/ClipboardPermissionTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MisttyTests/Models/ClipboardPermissionTests.swift`:

```swift
import XCTest

@testable import Mistty

final class ClipboardPermissionTests: XCTestCase {
  func test_global_usedWhenNoOverrides() {
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .allow, processRule: nil, sessionOverride: nil), .allow)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .prompt, processRule: nil, sessionOverride: nil), .prompt)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .deny, processRule: nil, sessionOverride: nil), .deny)
  }

  func test_processRule_beatsGlobal() {
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .deny, processRule: .allow, sessionOverride: nil), .allow)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .allow, processRule: .deny, sessionOverride: nil), .deny)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .allow, processRule: .prompt, sessionOverride: nil),
      .prompt)
  }

  func test_sessionOverride_beatsEverything() {
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .deny, processRule: .deny, sessionOverride: .allow),
      .allow)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .allow, processRule: .allow, sessionOverride: .deny),
      .deny)
  }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --skip Benchmark --filter ClipboardPermissionTests 2>&1 | tee /tmp/clip-test.log`
Expected: compile FAILURE — `cannot find 'ClipboardPermission'`.

- [ ] **Step 3: Implement**

Create `Mistty/Models/ClipboardPermission.swift`:

```swift
/// Pure precedence logic for OSC-52 clipboard-read decisions. The
/// side-effecting parts (resolving the pane's process, prompting, persisting)
/// live in `ClipboardPermissionCoordinator`; this is the testable core.
enum ClipboardPermission {
  /// Most specific wins: in-memory session override → persisted per-process
  /// rule → global default.
  static func resolve(
    global: ClipboardReadMode,
    processRule: ClipboardReadMode?,
    sessionOverride: ClipboardReadMode?
  ) -> ClipboardReadMode {
    sessionOverride ?? processRule ?? global
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --skip Benchmark --filter ClipboardPermissionTests 2>&1 | tee /tmp/clip-test.log`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/ClipboardPermission.swift MisttyTests/Models/ClipboardPermissionTests.swift
git commit -m "feat(clipboard): pure permission precedence core

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Coordinator — session overrides + resolution + persistence

**Files:**
- Create: `Mistty/Services/ClipboardPermissionCoordinator.swift`
- Test: Create `MisttyTests/Services/ClipboardPermissionCoordinatorTests.swift`

This task builds the testable, non-FFI surface of the coordinator: session-override
storage, the combined `decision(...)`, and the prompt-choice effect application.
The FFI entry (`decide(paneID:surface:state:content:)`) and the sheet land in
Tasks 5–6.

- [ ] **Step 1: Write the failing tests**

Create `MisttyTests/Services/ClipboardPermissionCoordinatorTests.swift`:

```swift
import XCTest

@testable import Mistty

@MainActor
final class ClipboardPermissionCoordinatorTests: XCTestCase {
  func test_decision_usesConfigWhenNoSessionOverride() {
    let coord = ClipboardPermissionCoordinator()
    var config = MisttyConfig()
    config.clipboardRead = .deny
    config.clipboardProcessRules = [.init(name: "nvim", mode: .allow)]

    XCTAssertEqual(coord.decision(forExecutable: "nvim", sessionID: 1, config: config), .allow)
    XCTAssertEqual(coord.decision(forExecutable: "zsh", sessionID: 1, config: config), .deny)
  }

  func test_sessionOverride_winsAndIsScopedToSession() {
    let coord = ClipboardPermissionCoordinator()
    let config = MisttyConfig()  // global .prompt
    coord.setSessionOverride(.allow, executable: "nvim", sessionID: 1)

    XCTAssertEqual(coord.decision(forExecutable: "nvim", sessionID: 1, config: config), .allow)
    // Different session → no override → falls back to global .prompt.
    XCTAssertEqual(coord.decision(forExecutable: "nvim", sessionID: 2, config: config), .prompt)
  }

  func test_clearSession_dropsOverrides() {
    let coord = ClipboardPermissionCoordinator()
    let config = MisttyConfig()
    coord.setSessionOverride(.allow, executable: "nvim", sessionID: 1)
    coord.clearSession(1)
    XCTAssertEqual(coord.decision(forExecutable: "nvim", sessionID: 1, config: config), .prompt)
  }

  func test_applyChoice_effects() {
    let coord = ClipboardPermissionCoordinator()

    // allowOnce / denyOnce: no session override, no persisted rule.
    let allowOnce = coord.applyChoice(.allowOnce, executable: "a", sessionID: 1)
    XCTAssertTrue(allowOnce.allowed)
    XCTAssertNil(allowOnce.persist)
    let denyOnce = coord.applyChoice(.denyOnce, executable: "a", sessionID: 1)
    XCTAssertFalse(denyOnce.allowed)
    XCTAssertNil(denyOnce.persist)

    // session choice sets an in-memory override, persists nothing.
    let session = coord.applyChoice(.allowSession, executable: "b", sessionID: 1)
    XCTAssertTrue(session.allowed)
    XCTAssertNil(session.persist)
    XCTAssertEqual(coord.decision(forExecutable: "b", sessionID: 1, config: MisttyConfig()), .allow)

    // always choices return a persisted rule for the caller to write.
    let allowAlways = coord.applyChoice(.allowAlways, executable: "c", sessionID: 1)
    XCTAssertTrue(allowAlways.allowed)
    XCTAssertEqual(allowAlways.persist, .init(name: "c", mode: .allow))
    let denyAlways = coord.applyChoice(.denyAlways, executable: "d", sessionID: 1)
    XCTAssertFalse(denyAlways.allowed)
    XCTAssertEqual(denyAlways.persist, .init(name: "d", mode: .deny))
  }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --skip Benchmark --filter ClipboardPermissionCoordinatorTests 2>&1 | tee /tmp/clip-test.log`
Expected: compile FAILURE — `cannot find 'ClipboardPermissionCoordinator'`.

- [ ] **Step 3: Implement the coordinator's non-FFI core**

Create `Mistty/Services/ClipboardPermissionCoordinator.swift`:

```swift
import AppKit
import GhosttyKit

/// Owns OSC-52 clipboard-read permission decisions: in-memory session
/// overrides, resolution against config + the pure `ClipboardPermission` core,
/// the prompt sheet, and persistence of "always" choices. Reachable from the
/// libghostty callback via `.shared`, configured with the WindowsStore at app
/// start (same pattern as NotificationService.shared.start).
@MainActor
final class ClipboardPermissionCoordinator {
  static let shared = ClipboardPermissionCoordinator()

  /// The five prompt outcomes.
  enum Choice {
    case allowOnce, allowAlways, allowSession, denyOnce, denyAlways
  }

  /// Result of applying a choice: whether to allow this request, plus an
  /// optional per-process rule the caller should persist (for "always"
  /// choices). Returning the rule instead of stashing it keeps `applyChoice`
  /// free of hidden state and disk I/O, so it stays unit-testable.
  struct ChoiceResult: Equatable {
    let allowed: Bool
    let persist: ClipboardProcessRule?
  }

  private weak var windowsStore: WindowsStore?

  /// In-memory, session-scoped overrides keyed by "<sessionID>\u{0}<exe>".
  private var sessionOverrides: [String: ClipboardReadMode] = [:]

  init() {}

  /// Wire up the store (called once from MisttyApp.init).
  func start(windowsStore: WindowsStore) {
    self.windowsStore = windowsStore
  }

  private func key(_ sessionID: Int, _ executable: String) -> String {
    "\(sessionID)\u{0}\(executable)"
  }

  // MARK: - Session overrides

  func setSessionOverride(_ mode: ClipboardReadMode, executable: String, sessionID: Int) {
    sessionOverrides[key(sessionID, executable)] = mode
  }

  func sessionOverride(executable: String, sessionID: Int) -> ClipboardReadMode? {
    sessionOverrides[key(sessionID, executable)]
  }

  /// Drop all overrides for a session (called when the session closes).
  func clearSession(_ sessionID: Int) {
    let prefix = "\(sessionID)\u{0}"
    sessionOverrides = sessionOverrides.filter { !$0.key.hasPrefix(prefix) }
  }

  // MARK: - Decision

  /// Resolve the effective mode for `executable` in `sessionID` against the
  /// given config and current session overrides.
  func decision(
    forExecutable executable: String, sessionID: Int, config: MisttyConfig
  ) -> ClipboardReadMode {
    ClipboardPermission.resolve(
      global: config.clipboardRead,
      processRule: config.clipboardProcessRule(for: executable),
      sessionOverride: sessionOverride(executable: executable, sessionID: sessionID))
  }

  // MARK: - Prompt choices

  /// Apply a prompt outcome: set a session override when needed and report
  /// whether to allow this request plus any per-process rule to persist.
  @discardableResult
  func applyChoice(_ choice: Choice, executable: String, sessionID: Int) -> ChoiceResult {
    switch choice {
    case .allowOnce:
      return ChoiceResult(allowed: true, persist: nil)
    case .denyOnce:
      return ChoiceResult(allowed: false, persist: nil)
    case .allowSession:
      setSessionOverride(.allow, executable: executable, sessionID: sessionID)
      return ChoiceResult(allowed: true, persist: nil)
    case .allowAlways:
      return ChoiceResult(
        allowed: true, persist: ClipboardProcessRule(name: executable, mode: .allow))
    case .denyAlways:
      return ChoiceResult(
        allowed: false, persist: ClipboardProcessRule(name: executable, mode: .deny))
    }
  }

  /// Persist a per-process rule to config: update `MisttyConfig.current`, save
  /// to disk, and post `.misttyConfigDidReload` so ConfigStore stays in sync.
  /// Save failures are logged, not fatal — the in-memory decision still applied.
  func persist(_ rule: ClipboardProcessRule) {
    let updated = MisttyConfig.current.settingClipboardProcessRule(
      name: rule.name, mode: rule.mode)
    MisttyConfig.current = updated
    do {
      try updated.save()
    } catch {
      DebugLog.shared.log("clipboard", "failed to persist process rule: \(error)")
    }
    NotificationCenter.default.post(name: .misttyConfigDidReload, object: nil)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift build 2>&1 | tee /tmp/clip-build.log && swift test --skip Benchmark --filter ClipboardPermissionCoordinatorTests 2>&1 | tee /tmp/clip-test.log`
Expected: build PASS; 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/ClipboardPermissionCoordinator.swift MisttyTests/Services/ClipboardPermissionCoordinatorTests.swift
git commit -m "feat(clipboard): permission coordinator (session overrides, decision, persist)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Prompt sheet + FFI `decide` entry

**Files:**
- Modify: `Mistty/Services/ClipboardPermissionCoordinator.swift` (add `decide` + `presentPrompt`)

No unit test — this is AppKit sheet + libghostty completion (manual coverage in
Task 6 / the test plan). Build-verified.

- [ ] **Step 1: Add `decide` and `presentPrompt`**

In `ClipboardPermissionCoordinator`, add:

```swift
  // MARK: - libghostty entry

  /// Decide an OSC-52 read request and complete it. Called on the main actor
  /// from the clipboard callback. `content` is the clipboard text already read
  /// by libghostty; `state`/`surface` belong to the open request.
  func decide(
    paneID: Int, surface: ghostty_surface_t,
    state: UnsafeMutableRawPointer, content: String
  ) {
    guard let resolved = windowsStore?.pane(byId: paneID) else {
      complete(surface: surface, state: state, allow: false, content: content)
      return
    }
    let executable = ForegroundProcessResolver.current(for: resolved.pane)?.executable
      ?? "(unknown)"
    let sessionID = resolved.session.id

    switch decision(
      forExecutable: executable, sessionID: sessionID, config: MisttyConfig.current)
    {
    case .allow:
      complete(surface: surface, state: state, allow: true, content: content)
    case .deny:
      complete(surface: surface, state: state, allow: false, content: content)
    case .prompt:
      let window = windowsStore?.trackedNSWindow(byId: resolved.window.id)?.window
      guard let window else {
        // No visible window to host the sheet → never leak silently.
        complete(surface: surface, state: state, allow: false, content: content)
        return
      }
      presentPrompt(executable: executable, on: window) { [weak self] choice in
        guard let self else { return }
        let result = self.applyChoice(choice, executable: executable, sessionID: sessionID)
        if let rule = result.persist { self.persist(rule) }
        self.complete(
          surface: surface, state: state, allow: result.allowed, content: content)
      }
    }
  }

  private func complete(
    surface: ghostty_surface_t, state: UnsafeMutableRawPointer,
    allow: Bool, content: String
  ) {
    // Empty completion = deny; both free the request's state in the core.
    (allow ? content : "").withCString { ptr in
      ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
    }
  }

  private func presentPrompt(
    executable: String, on window: NSWindow, completion: @escaping (Choice) -> Void
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Allow “\(executable)” to read your clipboard?"
    alert.informativeText =
      "A program running in this pane is requesting your clipboard contents via OSC-52."
    // Order matters: first button is the default (rightmost / Return).
    alert.addButton(withTitle: "Deny Once")        // index 1000 (.alertFirstButtonReturn)
    alert.addButton(withTitle: "Allow Once")        // 1001
    alert.addButton(withTitle: "Allow in This Session")  // 1002
    alert.addButton(withTitle: "Allow Always")      // 1003
    alert.addButton(withTitle: "Deny Always")       // 1004
    alert.beginSheetModal(for: window) { response in
      MainActor.assumeIsolated {
        let choice: Choice
        switch response {
        case .alertFirstButtonReturn: choice = .denyOnce
        case NSApplication.ModalResponse(rawValue: 1001): choice = .allowOnce
        case NSApplication.ModalResponse(rawValue: 1002): choice = .allowSession
        case NSApplication.ModalResponse(rawValue: 1003): choice = .allowAlways
        case NSApplication.ModalResponse(rawValue: 1004): choice = .denyAlways
        default: choice = .denyOnce
        }
        completion(choice)
      }
    }
  }
```

(Default button is "Deny Once" — the safe choice if the user just hits Return.
The `beginSheetModal` handler isn't `@MainActor`-typed, so the body is wrapped
in `MainActor.assumeIsolated` to call the `@MainActor` `completion` — the same
pattern `NotificationService`/`GhosttyApp` use for main-queue callbacks. If a
given SDK already types the handler as `@MainActor @Sendable`, the wrapper is a
harmless no-op.)

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tee /tmp/clip-build.log`
Expected: build PASS.

- [ ] **Step 3: Run the full suite (no regressions)**

Run: `swift test --skip Benchmark 2>&1 | tee /tmp/clip-test.log`
Expected: only the 23 known ChromePolish failures.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Services/ClipboardPermissionCoordinator.swift
git commit -m "feat(clipboard): prompt sheet + libghostty decide entry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Wire callback, app startup, and session-close cleanup

**Files:**
- Modify: `Mistty/App/GhosttyApp.swift` (route OSC-52 reads to the coordinator)
- Modify: `Mistty/App/MisttyApp.swift` (configure the coordinator at start)
- Modify: `Mistty/Models/WindowState.swift` (clear session overrides on close)

- [ ] **Step 1: Route the callback through the coordinator**

In `Mistty/App/GhosttyApp.swift`, replace the OSC-52 `default:` branch of
`confirmReadClipboardCallback` (the temporary Task 1 version) with the deferred,
main-actor-hopping version:

```swift
  default:
    // OSC-52 read: resolve + decide on the main actor (may show a sheet). The
    // request's `state` stays valid until we complete it; copy the content now
    // (the C string is only valid for this callback) and retain the view across
    // the hop.
    guard let paneID = view.pane?.id else {
      ghostty_surface_complete_clipboard_request(surface, "", state, true)
      return
    }
    let content = String(cString: str)
    let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
    DispatchQueue.main.async {
      // `decide` is @MainActor; this main-queue closure isn't @MainActor-typed,
      // so assume isolation (same pattern as NotificationService/GhosttyApp).
      MainActor.assumeIsolated {
        let view = unmanagedView.takeRetainedValue()
        // Pane/surface gone before we could prompt → abandon (ghostty frees
        // pending requests when the surface is freed); never touch a dead surface.
        guard let liveSurface = view.surface else { return }
        ClipboardPermissionCoordinator.shared.decide(
          paneID: paneID, surface: liveSurface, state: state, content: content)
      }
    }
```

(The `PASTE` case above it is unchanged — it still completes synchronously with
the content.)

- [ ] **Step 2: Configure the coordinator at app start**

In `Mistty/App/MisttyApp.swift` `init()`, next to
`NotificationService.shared.start(windowsStore: _windowsStore.wrappedValue)`
(line ~43), add:

```swift
    ClipboardPermissionCoordinator.shared.start(windowsStore: _windowsStore.wrappedValue)
```

- [ ] **Step 3: Clear session overrides when a session closes**

In `Mistty/Models/WindowState.swift`, in `closeSession` (line ~50), after
`session.releaseAllResources()`, add:

```swift
    ClipboardPermissionCoordinator.shared.clearSession(session.id)
```

- [ ] **Step 4: Build + full suite**

Run: `swift build 2>&1 | tee /tmp/clip-build.log && swift test --skip Benchmark 2>&1 | tee /tmp/clip-test.log`
Expected: build PASS; only the 23 known ChromePolish failures.

- [ ] **Step 5: Manual verification (requires the app)**

`just bundle && open build/Mistty-dev.app`, then in a pane:
- With default config (`prompt`): `printf '\033]52;c;?\007'` → the sheet appears on that window asking about your shell's foreground exe. "Deny Once" → program gets nothing. Re-run → prompts again.
- "Allow Always" → re-run: no prompt, program receives the clipboard; check `config.toml` has a `[[clipboard.process]]` entry with `allow`.
- "Allow in This Session" → re-run: no prompt; close the session and reopen → prompts again (override cleared); no `config.toml` entry.
- Set global `allow_clipboard_read = "deny"` + Reload Config → reads denied with no prompt. Set `"allow"` → allowed with no prompt. A `[[clipboard.process]]` rule still overrides the global.
- Cmd+V paste works throughout.

- [ ] **Step 6: Commit**

```bash
git add Mistty/App/GhosttyApp.swift Mistty/App/MisttyApp.swift Mistty/Models/WindowState.swift
git commit -m "feat(clipboard): route OSC-52 reads through the permission coordinator

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Final verification
- [ ] Full suite: only the 23 known `ChromePolishSnapshotTests` failures.
- [ ] `ClipboardPermissionTests`, `ClipboardPermissionCoordinatorTests`, and the new `MisttyConfigTests` cases all green.
- [ ] Manual prompt flow (Task 6 Step 5) behaves per the effect table.
- [ ] `git log --oneline` shows the six task commits.

## Notes / deferred (per spec)
- No "Deny in this session" option (decided); trivial to add a `Choice.denySession`.
- No Settings UI for managing rules; they're prompt-written + hand-editable.
- Over SSH the exe is `ssh`/`mosh`, so the prompt names that — accepted.
