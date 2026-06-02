# OSC 9;4 Progress Bars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render OSC 9;4 progress reports from a pane as a determinate bottom-edge bar on the tab and a mirror in the sidebar row.

**Architecture:** libghostty already parses OSC 9;4 and fires `GHOSTTY_ACTION_PROGRESS_REPORT`. A new case in Mistty's ghostty action callback re-broadcasts it as an in-process `NotificationCenter` event. A single observer in `WindowsStore.init` maps it (via a pure, tested function) to `pane.progress: PaneProgress`. The tab exposes a computed `aggregateProgress` over its panes; a shared `TabProgressBar` SwiftUI view renders it on both the tab bar and the sidebar row. No vendored-ghostty changes.

**Tech Stack:** Swift 6, SwiftPM (files under `Mistty/` and `MisttyTests/` are auto-discovered — no `.xcodeproj`), SwiftUI + AppKit, `GhosttyKit` (vendored xcframework), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-31-osc-progress-bars-design.md`

---

## Background for the implementer

- **Build:** `swift build` compiles the app. `just test` runs `swift test --skip Benchmark`. Single test: `swift test --filter <Suite>/<method>`. These are slow — pipe to a log and grep/tail it rather than re-running: `swift test --filter X 2>&1 | tee /tmp/t.log | tail -20`.
- **Statically-typed TDD note:** in Swift a test referencing a not-yet-defined symbol fails by failing to **compile**. A build error naming the missing symbol IS the expected "red" state.
- **Pre-existing test noise:** the suite has ~23 `ChromePolishSnapshotTests` pixel-comparison failures unrelated to this work. "Green" means no *new* failures and all *new* tests pass.
- **Ghostty action callback** lives in `Mistty/App/GhosttyApp.swift` — a top-level `private let actionCallback` (a C function pointer), a big `switch action.tag`. Surface-targeted cases decode payloads synchronously (the `action` struct is only valid during the callback), then `DispatchQueue.main.async` and post a `Notification.Name` carrying the pane id. `Notification.Name` values are declared in an `extension Notification.Name` in the same file. The OSC-notifications feature (`GHOSTTY_ACTION_DESKTOP_NOTIFICATION`, around line 118) is the exact precedent to copy.
- **C payload:** `vendor/ghostty/include/ghostty.h` defines the enum `GHOSTTY_ACTION_PROGRESS_REPORT`, the union member `progress_report` (access as `action.action.progress_report`), the payload `ghostty_action_progress_report_s { ghostty_action_progress_report_state_e state; int8_t progress; }`, and the state enum `GHOSTTY_PROGRESS_STATE_{REMOVE,SET,ERROR,INDETERMINATE,PAUSE}` (values 0–4 in that order). The imported Swift type exposes `state.rawValue` (a `UInt32`).
- **`WindowsStore`** (`Mistty/Models/WindowsStore.swift`, `@Observable @MainActor`) is the global window registry. `pane(byId:)` returns `(window, session, tab, pane)`. Its `init` already installs a `NotificationCenter` observer (for `NSWindow.didBecomeKeyNotification`) using the `[weak self] … MainActor.assumeIsolated { … }` pattern — copy that pattern for the new observer.
- **`MisttyPane`** and **`MisttyTab`** are both `@Observable @MainActor final class`. Observable transient state is a plain `var` (e.g. `MisttyPane.processTitle`, `MisttyTab.hasBell`). A computed property that reads child panes' `@Observable` state is tracked by SwiftUI.
- **Render sites:**
  - `TabBarItem` (`Mistty/Views/TabBar/TabBarView.swift`, ~line 43): an `HStack` with `.background(tabBackground)` then `.cornerRadius(5)`. The zoomed glyph and `hasBell` background are the indicator precedents.
  - `SidebarTabRow` (`Mistty/Views/Sidebar/SidebarView.swift`, ~line 197): an `HStack` with `.background { RoundedRectangle … }`, an `.overlay(alignment: .leading)` activity stripe, and `.overlay(alignment: .top/.bottom)` drop indicators.
- **Config:** `UIConfig` is a nested struct in `Mistty/Config/MisttyConfig.swift`. `[ui]` keys are parsed in `MisttyConfig.parse` (the `if let uiTable = table["ui"]?.table { … }` block) and serialized in `save()` (the `if ui != UIConfig() { … }` block). Views read `MisttyConfig.current.ui.*`; the whole view tree re-renders on `.misttyConfigDidReload` (MisttyApp refreshes its `@State config`), so a static read picks up reloads. Config tests live in `MisttyTests/Config/UIConfigTests.swift`.

---

## File Structure

- **Create** `Mistty/Models/PaneProgress.swift` — `PaneProgress` enum, `ProgressState` enum (Swift mirror of the C enum), `PaneProgress.from(state:percent:)` mapper, `PaneProgress.aggregate(_:)` reduction, and the view-agnostic `isIndeterminate` / `fillFraction` helpers. Pure, no SwiftUI, no GhosttyKit.
- **Create** `MisttyTests/Models/PaneProgressTests.swift` — mapper, aggregation, and helper tests.
- **Create** `Mistty/Views/ProgressBar/TabProgressBar.swift` — the shared SwiftUI bar view (determinate fill / indeterminate sweep / state color) used by both render sites.
- **Modify** `Mistty/Models/MisttyPane.swift` — add `var progress: PaneProgress = .none`.
- **Modify** `Mistty/Models/MisttyTab.swift` — add `var aggregateProgress: PaneProgress` computed property.
- **Modify** `Mistty/App/GhosttyApp.swift` — `.ghosttyProgressReport` name + `GHOSTTY_ACTION_PROGRESS_REPORT` case.
- **Modify** `Mistty/Models/WindowsStore.swift` — observer in `init` that writes `pane.progress`.
- **Modify** `Mistty/App/ContentView.swift` — clear `pane.progress` on surface close (defensive).
- **Modify** `Mistty/Config/MisttyConfig.swift` — `UIConfig.progressBar` parse + save.
- **Modify** `MisttyTests/Config/UIConfigTests.swift` — `progressBar` parse / round-trip tests.
- **Modify** `Mistty/Views/TabBar/TabBarView.swift` + `Mistty/Views/Sidebar/SidebarView.swift` — overlay the bar, gated on config.
- **Modify** `docs/config-example.toml` + `PLAN.md` — docs.

---

## Task 1: `PaneProgress` model — type, mapper, aggregation, helpers

**Files:**
- Create: `Mistty/Models/PaneProgress.swift`
- Test: `MisttyTests/Models/PaneProgressTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MisttyTests/Models/PaneProgressTests.swift`:

```swift
import XCTest

@testable import Mistty

final class PaneProgressTests: XCTestCase {
  // MARK: from(state:percent:)

  func test_from_remove_isNone() {
    XCTAssertEqual(PaneProgress.from(state: .remove, percent: 42), .none)
    XCTAssertEqual(PaneProgress.from(state: .remove, percent: -1), .none)
  }

  func test_from_set_withPercent_isRunning() {
    XCTAssertEqual(PaneProgress.from(state: .set, percent: 45), .running(45))
    XCTAssertEqual(PaneProgress.from(state: .set, percent: 0), .running(0))
    XCTAssertEqual(PaneProgress.from(state: .set, percent: 100), .running(100))
  }

  func test_from_set_withoutPercent_isIndeterminate() {
    XCTAssertEqual(PaneProgress.from(state: .set, percent: -1), .indeterminate)
  }

  func test_from_indeterminate() {
    XCTAssertEqual(PaneProgress.from(state: .indeterminate, percent: -1), .indeterminate)
    XCTAssertEqual(PaneProgress.from(state: .indeterminate, percent: 50), .indeterminate)
  }

  func test_from_pause() {
    XCTAssertEqual(PaneProgress.from(state: .pause, percent: 60), .paused(60))
    XCTAssertEqual(PaneProgress.from(state: .pause, percent: -1), .paused(nil))
  }

  func test_from_error() {
    XCTAssertEqual(PaneProgress.from(state: .error, percent: 30), .error(30))
    XCTAssertEqual(PaneProgress.from(state: .error, percent: -1), .error(nil))
  }

  func test_from_clampsOutOfRange() {
    XCTAssertEqual(PaneProgress.from(state: .set, percent: 150), .running(100))
    XCTAssertEqual(PaneProgress.from(state: .error, percent: 999), .error(100))
  }

  // MARK: aggregate(_:)

  func test_aggregate_empty_isNone() {
    XCTAssertEqual(PaneProgress.aggregate([]), .none)
  }

  func test_aggregate_allNone_isNone() {
    XCTAssertEqual(PaneProgress.aggregate([.none, .none]), .none)
  }

  func test_aggregate_singleRunning() {
    XCTAssertEqual(PaneProgress.aggregate([.none, .running(70)]), .running(70))
  }

  func test_aggregate_errorWins() {
    XCTAssertEqual(
      PaneProgress.aggregate([.running(90), .error(20), .indeterminate]), .error(20))
  }

  func test_aggregate_errorWithoutPercent() {
    XCTAssertEqual(PaneProgress.aggregate([.running(90), .error(nil)]), .error(nil))
  }

  func test_aggregate_errorLeastComplete() {
    XCTAssertEqual(PaneProgress.aggregate([.error(80), .error(20)]), .error(20))
  }

  func test_aggregate_indeterminateOverRunning() {
    XCTAssertEqual(PaneProgress.aggregate([.running(50), .indeterminate]), .indeterminate)
  }

  func test_aggregate_leastCompleteRunning() {
    XCTAssertEqual(PaneProgress.aggregate([.running(80), .running(30)]), .running(30))
  }

  func test_aggregate_runningBeatsPausedForState_butMinPercent() {
    // any running → .running, percent is the least-complete across running+paused
    XCTAssertEqual(PaneProgress.aggregate([.running(80), .paused(30)]), .running(30))
  }

  func test_aggregate_allPaused() {
    XCTAssertEqual(PaneProgress.aggregate([.paused(40), .paused(70)]), .paused(40))
  }

  // MARK: view helpers

  func test_isIndeterminate() {
    XCTAssertTrue(PaneProgress.indeterminate.isIndeterminate)
    XCTAssertFalse(PaneProgress.running(10).isIndeterminate)
    XCTAssertFalse(PaneProgress.none.isIndeterminate)
  }

  func test_fillFraction() {
    XCTAssertEqual(PaneProgress.running(50).fillFraction, 0.5)
    XCTAssertEqual(PaneProgress.paused(25).fillFraction, 0.25)
    XCTAssertEqual(PaneProgress.error(100).fillFraction, 1.0)
    XCTAssertNil(PaneProgress.error(nil).fillFraction)
    XCTAssertNil(PaneProgress.indeterminate.fillFraction)
    XCTAssertNil(PaneProgress.none.fillFraction)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PaneProgressTests 2>&1 | tee /tmp/p1.log | tail -20`
Expected: build failure — `cannot find 'PaneProgress' in scope` / `cannot find type 'ProgressState'`.

- [ ] **Step 3: Create the model file**

Create `Mistty/Models/PaneProgress.swift`:

```swift
import Foundation

/// Swift mirror of libghostty's `ghostty_action_progress_report_state_e`.
/// Raw values match the C enum's declaration order (REMOVE=0 … PAUSE=4) so
/// the action callback can post the raw `Int` and the consumer can rebuild
/// this without importing GhosttyKit into the test target.
enum ProgressState: Int {
  case remove = 0
  case set
  case error
  case indeterminate
  case pause
}

/// How a pane's OSC 9;4 progress should render. Single source of truth for
/// the progress bar.
enum PaneProgress: Equatable {
  case none            // no bar
  case running(Int)    // 0–100, determinate fill
  case indeterminate   // animated sweep (percent unknown)
  case paused(Int?)    // amber; optional fill
  case error(Int?)     // red; optional fill

  /// Map a decoded libghostty progress report to a `PaneProgress`.
  /// `percent` is the raw `int8` value: `-1` means "no percent reported".
  static func from(state: ProgressState, percent: Int) -> PaneProgress {
    // nil for the -1 sentinel (or any negative); otherwise clamp to 0…100.
    let pct: Int? = percent < 0 ? nil : min(percent, 100)
    switch state {
    case .remove: return .none
    case .set: return pct.map { .running($0) } ?? .indeterminate
    case .indeterminate: return .indeterminate
    case .pause: return .paused(pct)
    case .error: return .error(pct)
    }
  }

  /// Combine the per-pane progress of every pane in a tab into one bar.
  /// Precedence over actively-reporting panes (ignoring `.none`):
  ///   1. any `.error` → `.error(least-complete error percent, if any)`
  ///   2. any `.indeterminate` → `.indeterminate`
  ///   3. else `.running`/`.paused` → least-complete percent; `.running` if
  ///      any pane is running, else `.paused`
  ///   4. nothing reporting → `.none`
  static func aggregate(_ items: [PaneProgress]) -> PaneProgress {
    let active = items.filter { $0 != .none }
    if active.isEmpty { return .none }

    var hasError = false
    var errorPercents: [Int] = []
    for case .error(let pct) in active {
      hasError = true
      if let pct { errorPercents.append(pct) }
    }
    if hasError { return .error(errorPercents.min()) }

    for case .indeterminate in active { return .indeterminate }

    var anyRunning = false
    var percents: [Int] = []
    for p in active {
      switch p {
      case .running(let v): anyRunning = true; percents.append(v)
      case .paused(let v): if let v { percents.append(v) }
      default: break  // .none/.indeterminate/.error already handled
      }
    }
    let minPct = percents.min() ?? 0
    return anyRunning ? .running(minPct) : .paused(minPct)
  }

  /// True only for the indeterminate state (drives the animated sweep).
  var isIndeterminate: Bool {
    if case .indeterminate = self { return true }
    return false
  }

  /// Determinate fill fraction (0…1), or `nil` when there is no percent to
  /// show (indeterminate, a state carrying no percent, or `.none`).
  var fillFraction: Double? {
    switch self {
    case .running(let p): return Double(p) / 100
    case .paused(let p), .error(let p): return p.map { Double($0) / 100 }
    case .indeterminate, .none: return nil
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PaneProgressTests 2>&1 | tee /tmp/p1.log | tail -20`
Expected: PASS — `Executed 19 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/PaneProgress.swift MisttyTests/Models/PaneProgressTests.swift
git commit -m "feat(progress): add PaneProgress model, mapper, and aggregation"
```

---

## Task 2: Per-pane and per-tab progress state

Build-verified (the aggregation logic itself is already unit-tested in Task 1; `MisttyTab.aggregateProgress` is a one-line delegation).

**Files:**
- Modify: `Mistty/Models/MisttyPane.swift`
- Modify: `Mistty/Models/MisttyTab.swift`

- [ ] **Step 1: Add `progress` to `MisttyPane`**

In `Mistty/Models/MisttyPane.swift`, add this stored property immediately after `var processTitle: String?` (around line 38):

```swift
  /// Live OSC 9;4 progress for this pane. Ephemeral runtime state (like
  /// `processTitle`); never persisted in a snapshot.
  var progress: PaneProgress = .none
```

- [ ] **Step 2: Add `aggregateProgress` to `MisttyTab`**

In `Mistty/Models/MisttyTab.swift`, add this computed property immediately after the `var hasBell = false` line (around line 21):

```swift
  /// Combined progress across this tab's panes, for the tab-level bar.
  /// Reading each pane's `progress` here means `@Observable` re-renders the
  /// bar when any pane updates.
  var aggregateProgress: PaneProgress {
    PaneProgress.aggregate(panes.map(\.progress))
  }
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tee /tmp/p2.log | tail -8`
Expected: `Build complete!` (the two pre-existing libghostty/ImGui linker warnings are fine).

- [ ] **Step 4: Commit**

```bash
git add Mistty/Models/MisttyPane.swift Mistty/Models/MisttyTab.swift
git commit -m "feat(progress): per-pane progress state + tab aggregate"
```

---

## Task 3: Re-broadcast the ghostty progress-report action

Build-verified (the callback is a C function pointer driven by libghostty).

**Files:**
- Modify: `Mistty/App/GhosttyApp.swift`

- [ ] **Step 1: Add the notification name**

In `Mistty/App/GhosttyApp.swift`, in the `extension Notification.Name` block (alongside `ghosttyDesktopNotification`, `ghosttyRingBell`, etc.), add:

```swift
  static let ghosttyProgressReport = Notification.Name("ghosttyProgressReport")
```

- [ ] **Step 2: Add the action case**

In `actionCallback`'s `switch action.tag`, add this case immediately before the `default:` case:

```swift
  case GHOSTTY_ACTION_PROGRESS_REPORT:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      let report = action.action.progress_report
      // Decode synchronously — `action` is only valid during this callback.
      let stateRaw = Int(report.state.rawValue)
      let percent = Int(report.progress)
      DispatchQueue.main.async {
        guard let userdata = ghostty_surface_userdata(surface) else { return }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        NotificationCenter.default.post(
          name: .ghosttyProgressReport,
          object: nil,
          userInfo: ["paneID": view.pane?.id as Any, "state": stateRaw, "progress": percent]
        )
      }
    }
    return true
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tee /tmp/p3.log | tail -8`
Expected: `Build complete!`. (`GHOSTTY_ACTION_PROGRESS_REPORT` and `progress_report` are in `vendor/ghostty/include/ghostty.h`. If the build says they don't exist, STOP and report — do not invent alternatives.)

- [ ] **Step 4: Commit**

```bash
git add Mistty/App/GhosttyApp.swift
git commit -m "feat(progress): re-broadcast ghostty progress-report action"
```

---

## Task 4: Consume the event + lifecycle clearing

Build-verified (NotificationCenter wiring + model mutation; not unit-testable without the app running).

**Files:**
- Modify: `Mistty/Models/WindowsStore.swift`
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Install the consumer in `WindowsStore.init`**

In `Mistty/Models/WindowsStore.swift`, find the existing `init()` that installs the `NSWindow.didBecomeKeyNotification` observer. Immediately after that `addObserver(...)` call (still inside `init`), add a second observer:

```swift
    // Map OSC 9;4 progress reports onto the emitting pane. A single consumer
    // here (rather than per-window in ContentView) avoids redundant writes.
    NotificationCenter.default.addObserver(
      forName: .ghosttyProgressReport,
      object: nil,
      queue: .main
    ) { [weak self] note in
      let paneID = note.userInfo?["paneID"] as? Int
      let stateRaw = note.userInfo?["state"] as? Int ?? -1
      let percent = note.userInfo?["progress"] as? Int ?? -1
      MainActor.assumeIsolated {
        guard let self, let paneID,
          let state = ProgressState(rawValue: stateRaw),
          let resolved = self.pane(byId: paneID)
        else { return }
        resolved.pane.progress = PaneProgress.from(state: state, percent: percent)
      }
    }
```

- [ ] **Step 2: Clear progress when a surface closes**

In `Mistty/App/ContentView.swift`, in `handleCloseSurface(_:)`, the non-popup branch closes the pane:

```swift
    // Find and close the pane whose shell exited
    if let resolved = windowsStore.pane(byId: paneID) {
      closePaneInTab(resolved.pane, tab: resolved.tab, session: resolved.session)
    }
```

Change it to clear progress before closing (defensive — `closePaneInTab` already drops the pane from `tab.panes`, so it stops contributing to `aggregateProgress`, but this guarantees no stale read during teardown):

```swift
    // Find and close the pane whose shell exited
    if let resolved = windowsStore.pane(byId: paneID) {
      resolved.pane.progress = .none
      closePaneInTab(resolved.pane, tab: resolved.tab, session: resolved.session)
    }
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tee /tmp/p4.log | tail -8`
Expected: `Build complete!`.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Models/WindowsStore.swift Mistty/App/ContentView.swift
git commit -m "feat(progress): consume progress reports + clear on close"
```

---

## Task 5: `[ui] progress_bar` config toggle

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift`
- Test: `MisttyTests/Config/UIConfigTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these methods to the `UIConfigTests` class in `MisttyTests/Config/UIConfigTests.swift` (before the closing brace):

```swift
  // MARK: progress_bar

  func test_progressBar_defaultsTrue() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertTrue(config.ui.progressBar)
  }

  func test_progressBar_explicitFalse() throws {
    let config = try MisttyConfig.parse("""
      [ui]
      progress_bar = false
      """)
    XCTAssertFalse(config.ui.progressBar)
  }

  func test_progressBar_missingUITableDefaultsTrue() throws {
    let config = try MisttyConfig.parse("[ui]")
    XCTAssertTrue(config.ui.progressBar)
  }

  func test_progressBar_roundTrip() throws {
    var config = MisttyConfig()
    config.ui.progressBar = false
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-progressbar-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.ui.progressBar, false)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UIConfigTests/test_progressBar 2>&1 | tee /tmp/p5.log | tail -20`
Expected: build failure — `value of type 'UIConfig' has no member 'progressBar'`.

- [ ] **Step 3: Add the `progressBar` field**

In `Mistty/Config/MisttyConfig.swift`, in `struct UIConfig`, add this stored property after `var paneBorderWidth: Int = 1`:

```swift
  /// When false, hides the OSC 9;4 progress bars on tabs and sidebar rows.
  var progressBar: Bool = true
```

- [ ] **Step 4: Parse `progress_bar`**

In `MisttyConfig.parse`, inside the `if let uiTable = table["ui"]?.table { … }` block, add after the `pane_border_width` parse:

```swift
      if let pb = uiTable["progress_bar"]?.bool {
        config.ui.progressBar = pb
      }
```

- [ ] **Step 5: Serialize `progress_bar`**

In `MisttyConfig.save`, inside the `if ui != UIConfig() { … }` block, add after the `pane_border_width` serialization:

```swift
      if ui.progressBar != UIConfig().progressBar {
        lines.append("progress_bar = \(ui.progressBar)")
      }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter UIConfigTests/test_progressBar 2>&1 | tee /tmp/p5.log | tail -20`
Expected: PASS — `Executed 4 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift MisttyTests/Config/UIConfigTests.swift
git commit -m "feat(progress): add [ui] progress_bar toggle"
```

---

## Task 6: `TabProgressBar` view + wire into both render sites

Build-verified (SwiftUI views aren't unit-tested here; the data they render is covered by Task 1).

**Files:**
- Create: `Mistty/Views/ProgressBar/TabProgressBar.swift`
- Modify: `Mistty/Views/TabBar/TabBarView.swift`
- Modify: `Mistty/Views/Sidebar/SidebarView.swift`

- [ ] **Step 1: Create the shared bar view**

Create `Mistty/Views/ProgressBar/TabProgressBar.swift`:

```swift
import SwiftUI

/// A 2pt progress bar driven by a `PaneProgress`. Renders nothing for
/// `.none`. Determinate states show a tinted track with a fill = percent;
/// `.indeterminate` shows an animated sweeping segment. Used as a bottom
/// overlay on both the tab-bar item and the sidebar row.
struct TabProgressBar: View {
  let progress: PaneProgress

  var body: some View {
    if progress != .none {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(color.opacity(0.25))
          if progress.isIndeterminate {
            Capsule()
              .fill(color)
              .frame(width: geo.size.width * 0.3)
              .modifier(IndeterminateSweep(trackWidth: geo.size.width))
          } else {
            Capsule()
              .fill(color)
              .frame(width: geo.size.width * CGFloat(progress.fillFraction ?? 1))
          }
        }
      }
      .frame(height: 2)
    }
  }

  private var color: Color {
    switch progress {
    case .error: return .red
    case .paused: return .orange
    case .running, .indeterminate: return .accentColor
    case .none: return .clear
    }
  }
}

/// Slides a segment left↔right to convey indeterminate progress. The segment
/// is `0.3 × trackWidth` wide (see caller), so it travels from fully-left to
/// fully-right within the track.
private struct IndeterminateSweep: ViewModifier {
  let trackWidth: CGFloat
  @State private var atEnd = false

  func body(content: Content) -> some View {
    content
      .offset(x: atEnd ? trackWidth * 0.7 : 0)
      .onAppear {
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
          atEnd = true
        }
      }
  }
}
```

- [ ] **Step 2: Overlay the bar on the tab-bar item**

In `Mistty/Views/TabBar/TabBarView.swift`, in `TabBarItem.body`, the `HStack { … }` already chains `.background(tabBackground)` then `.cornerRadius(5)`. Add a bottom overlay immediately after `.cornerRadius(5)`:

```swift
    .overlay(alignment: .bottom) {
      if MisttyConfig.current.ui.progressBar {
        TabProgressBar(progress: tab.aggregateProgress)
          .padding(.horizontal, 4)
          .padding(.bottom, 1)
      }
    }
```

(Place it so the `.onTapGesture { onSelect() }` and `.onReceive(...)` that follow stay attached to the same view chain — i.e. insert the `.overlay` right after `.cornerRadius(5)` and before `.onTapGesture`.)

- [ ] **Step 3: Overlay the bar on the sidebar row**

In `Mistty/Views/Sidebar/SidebarView.swift`, in `SidebarTabRow.body`, find the existing `.overlay(alignment: .leading) { … }` activity-stripe block. Immediately after it, add:

```swift
    .overlay(alignment: .bottom) {
      if MisttyConfig.current.ui.progressBar {
        TabProgressBar(progress: tab.aggregateProgress)
          .padding(.horizontal, 6)
      }
    }
```

- [ ] **Step 4: Build to verify**

Run: `swift build 2>&1 | tee /tmp/p6.log | tail -8`
Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/ProgressBar/TabProgressBar.swift Mistty/Views/TabBar/TabBarView.swift Mistty/Views/Sidebar/SidebarView.swift
git commit -m "feat(progress): render progress bar on tab bar and sidebar"
```

---

## Task 7: Documentation

**Files:**
- Modify: `docs/config-example.toml`
- Modify: `PLAN.md`

- [ ] **Step 1: Document `[ui] progress_bar` in the example config**

In `docs/config-example.toml`, inside the `[ui]` section, add (place it near the other `[ui]` keys, e.g. after the `pane_border_width` documentation/line):

```toml
# Show a progress bar on tabs / sidebar rows when a program in the pane
# emits an OSC 9;4 progress report (builds, downloads, package managers).
# Color-coded: running (accent), paused (amber), error (red). Set to false
# to hide them. Default: true.
# progress_bar = true
```

- [ ] **Step 2: Update `PLAN.md` — remove the old TODO line**

In `PLAN.md`, under `### Misc & Bugs` → `Larger:`, the OSC line currently reads (after the notifications work):

```markdown
- OSC 99 (Kitty notification protocol) — needs a libghostty Zig parser patch (new OSC parser + action plumbing). OSC 9 + OSC 777 shipped (see `## Implemented`). Spec context: `docs/superpowers/specs/2026-05-21-osc-notifications-design.md`.
```

Leave that line as-is (OSC 99 is still outstanding). No removal needed — OSC 9;4 progress was not a separate TODO bullet.

- [ ] **Step 3: Update `PLAN.md` — add the Implemented entry**

In `PLAN.md`, under `## Implemented`, add this section immediately after the `### OSC desktop notifications` section and before `### Multi-window v1`:

```markdown
### OSC 9;4 progress bars

Spec: `docs/superpowers/specs/2026-05-31-osc-progress-bars-design.md`. Plan: `docs/superpowers/plans/2026-06-02-osc-progress-bars.md`.

- OSC 9;4 progress reports (running 0–100%, error, indeterminate, paused, remove) render as a 2pt color-coded bar on the bottom edge of the tab and a mirror on the sidebar row. libghostty parses the sequence into `GHOSTTY_ACTION_PROGRESS_REPORT`; a new case in `GhosttyApp.swift`'s `actionCallback` re-broadcasts it as `.ghosttyProgressReport`
- A pure `PaneProgress` value type (in `Mistty/Models/PaneProgress.swift`) with `from(state:percent:)` mapper and `aggregate(_:)` reduction — both unit-tested. State lives on `MisttyPane.progress` (ephemeral, never snapshotted); `MisttyTab.aggregateProgress` reduces across the tab's panes (error wins, else indeterminate, else least-complete percent)
- A single observer in `WindowsStore.init` maps the event onto the emitting pane (no new singleton — a progress report is a pure model write, unlike the notification feature's `UNUserNotificationCenter` delegate). Progress clears on `REMOVE` and on pane close
- Shared `TabProgressBar` SwiftUI view (determinate fill / animated indeterminate sweep) used by both render sites; gated on `[ui] progress_bar` (default true)
```

- [ ] **Step 4: Commit**

```bash
git add docs/config-example.toml PLAN.md
git commit -m "docs: document OSC 9;4 progress bars"
```

---

## Task 8: Final review + manual verification

- [ ] **Step 1: Full suite green (no new failures)**

Run: `just test 2>&1 | tee /tmp/p8.log | tail -25`
Expected: all new tests pass; the only failures are the pre-existing `ChromePolishSnapshotTests` (confirm the count matches the pre-feature baseline — no new failures).

- [ ] **Step 2: Manual verification**

Run: `just run`, then in a pane:

- `printf '\e]9;4;1;45\a'` → tab bar + sidebar show a ~45% accent-colored bar.
- `printf '\e]9;4;1;100\a'` → bar fills; `printf '\e]9;4;0\a'` → bar clears.
- `printf '\e]9;4;2;30\a'` → red (error) bar; `printf '\e]9;4;3\a'` → animated indeterminate sweep; `printf '\e]9;4;4;60\a'` → amber paused bar.
- Split the pane (`cmd+d`); set one pane to `;1;80` and the other to `;1;30` → the tab/sidebar bar shows ~30% (least-complete). Set one to `;2;` (error) → the tab bar turns red.
- Hide the tab bar (`cmd+shift+b`) with the sidebar open → the sidebar row bar still shows.
- Add `[ui]\nprogress_bar = false` to `~/.config/mistty/config.toml`, `mistty-cli config reload` → bars disappear; set back to `true`, reload → a live bar reappears.
- Close a pane mid-progress → no stale bar.

- [ ] **Step 3: Final code review (optional, recommended)**

Dispatch a comprehensive reviewer over `git diff <base>..HEAD` for cross-task integration (userInfo key/type alignment between Task 3 and Task 4; `aggregateProgress` observability; the `ProgressState` raw-value ↔ ghostty enum order).

---

## Self-Review

**Spec coverage:**

- OSC 9;4 → tab + sidebar bar: Tasks 3, 4, 6. ✅
- `PaneProgress` enum + states: Task 1. ✅
- Pure `from(state:percent:)` mapper, all 5 states + `-1` + clamp: Task 1. ✅
- `ProgressState` Swift mirror (raw values match ghostty order): Task 1; consumed in Tasks 3–4. ✅
- `MisttyPane.progress` ephemeral, not snapshotted: Task 2 (no snapshot DTO touched). ✅
- `MisttyTab.aggregateProgress` computed, observability via reading panes' progress: Task 2. ✅
- Aggregation precedence (error wins → indeterminate → least-complete; running-vs-paused): Task 1 (`aggregate`), tested. ✅
- Single consumer in `WindowsStore.init` (no new singleton): Task 4. ✅
- Action re-broadcast mirrors notifications, synchronous decode: Task 3. ✅
- Clear on REMOVE (mapper → `.none`) and on pane close: Tasks 1 + 4. ✅
- Tab-bar bottom-edge bar + sidebar mirror, shared view, state colors, indeterminate animation: Task 6. ✅
- `[ui] progress_bar` default-true toggle, parse + save + gating + live reload: Tasks 5 + 6. ✅
- Tests — mapper, aggregation, helpers, config: Tasks 1 + 5. ✅
- Docs — config-example + PLAN: Task 7. ✅
- Out of scope (dock, title, persistence, auto-timeout): none implemented. ✅

**Placeholder scan:** none — every code step has complete code.

**Type consistency:** `PaneProgress` cases (`none`/`running(Int)`/`indeterminate`/`paused(Int?)`/`error(Int?)`) are identical across Tasks 1, 2, 4, 6. `ProgressState` (`remove`/`set`/`error`/`indeterminate`/`pause`, raw 0–4) defined in Task 1, reconstructed via `ProgressState(rawValue:)` in Task 4 from the `Int` posted in Task 3. `PaneProgress.from(state:percent:)` and `PaneProgress.aggregate(_:)` signatures match between definition (Task 1) and use (Tasks 2, 4). `TabProgressBar(progress:)` defined in Task 6 Step 1, used in Steps 2–3. `tab.aggregateProgress` defined Task 2, used Task 6. `UIConfig.progressBar` defined Task 5, read in Task 6. userInfo keys `paneID`/`state`/`progress` posted in Task 3, read in Task 4. ✅
