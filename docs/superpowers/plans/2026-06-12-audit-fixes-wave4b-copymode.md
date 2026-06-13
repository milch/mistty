# Audit Fixes Wave 4b: CopyModeController Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Move copy-mode's search/scroll/yank/hint *orchestration* (~470 lines, the riskiest untested code in the app) out of `ContentView` into a `@MainActor CopyModeController` that operates on `(inout CopyModeState, reader: TerminalContentReading)`, making the coordinate math unit-testable against a fake reader. `ContentView` keeps only the NSEvent-monitor plumbing and active-pane lookup.

**Architecture:** A `TerminalContentReading` protocol abstracts every surface interaction the orchestration needs; `TerminalSurfaceView` conforms. The controller is a stateless service (pure functions over state + reader), so a `FakeTerminalContent` drives it in tests. The pure value types it builds on already exist and are tested: `CopyModeState` (state machine), `SearchMatching` (jump math), `CopyModeYank` (selection normalize), `HintDetector`.

**Tech Stack:** Swift/SwiftPM, XCTest. Baseline: 23 ChromePolish failures = green; anything else is a regression.

---

### Task 1: Surface API + `TerminalContentReading` protocol (additive, behavior-preserving)

**Files:** `Mistty/Views/Terminal/TerminalSurfaceView.swift`, new `Mistty/Models/TerminalContentReading.swift`, `Mistty/App/ContentView.swift` (route copy-mode C calls through the new methods).

- [ ] Add to `TerminalSurfaceView` (near `readText`):
```swift
  /// Run a ghostty keybinding action by name (e.g. "scroll_to_bottom",
  /// "scroll_page_lines:5"). Centralizes the binding-action C call.
  @MainActor
  func runBindingAction(_ action: String) {
    guard let surface else { return }
    _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
  }

  /// Freeze the viewport at the current top row (transition .active → .pin)
  /// so streaming output doesn't scroll copy-mode selections out from under
  /// the user. Mistty patch 0005-pin-viewport.
  @MainActor
  func pinViewport() {
    guard let surface else { return }
    ghostty_surface_pin_viewport(surface)
  }
```
- [ ] Create `Mistty/Models/TerminalContentReading.swift`:
```swift
import GhosttyKit

/// The surface operations copy-mode orchestration needs. Abstracted so
/// `CopyModeController` can be driven by a fake in tests instead of a live
/// libghostty surface.
@MainActor
protocol TerminalContentReading: AnyObject {
  func readRow(_ row: Int, pointTag: ghostty_point_tag_e) -> String?
  func readText(
    startRow: Int, startCol: Int, endRow: Int, endCol: Int,
    rectangle: Bool, pointTag: ghostty_point_tag_e) -> String?
  func viewportGridSize() -> (rows: Int, cols: Int)?
  func cursorPosition() -> (row: Int, col: Int)?
  var scrollbarState: ScrollbarState { get set }
  func runBindingAction(_ action: String)
  func pinViewport()
}

extension TerminalSurfaceView: TerminalContentReading {}
```
(`readRow`/`readText`/`viewportGridSize`/`cursorPosition`/`scrollbarState` already exist on `TerminalSurfaceView` with matching signatures — the conformance is empty. `readRow`/`readText` have defaulted `pointTag`/`rectangle`; the protocol requirement is the un-defaulted form, which the existing methods satisfy.)
- [ ] In `ContentView`, replace the three copy-mode `ghostty_surface_binding_action(surface, …)` call sites (scrollViewport, exitCopyMode, runSearch) with `pane.surfaceView.runBindingAction(actionStr)`, the `ghostty_surface_pin_viewport(surface)` in enterCopyMode with `surfaceView.pinViewport()`, and the two `ghostty_surface_size(surface)` reads in copy-mode code with `surfaceView.viewportGridSize()`. Behavior identical.
- [ ] Build + full suite at baseline. Commit: `refactor(surface): binding-action/pin wrappers + TerminalContentReading protocol`.

---

### Task 2: `CopyModeController` + tests (logic extracted, ContentView not yet wired)

**Files:** new `Mistty/Models/CopyModeController.swift`, new `MisttyTests/Models/CopyModeControllerTests.swift`.

The controller carries verbatim the orchestration currently in ContentView, retargeted onto `reader: TerminalContentReading` instead of `pane.surfaceView`/`copyModePane`. Methods:

```swift
@MainActor
final class CopyModeController {
  struct Config { var scrolloff: Int; var hintAlphabet: String; var hintUppercaseAction: HintAction }
  enum KeyResult { case consume, passThrough, exit }

  /// enterCopyMode's dimension + cursor-anchor + pin logic (minus the
  /// window-mode side effect, which stays in ContentView).
  func makeInitialState(reader: TerminalContentReading) -> CopyModeState

  /// scrollViewport: binding-action + synchronous offset clamp + anchor
  /// adjustment by the ACTUAL delta. Returns the applied delta.
  @discardableResult
  func scrollViewport(_ state: inout CopyModeState, delta: Int, reader: TerminalContentReading) -> Int

  /// runSearch: cached single-pass scan + SearchMatching jump + center scroll.
  func runSearch(_ state: inout CopyModeState, direction: SearchDirection, reader: TerminalContentReading)

  /// scanViewport + HintDetector → state.setHintMatches.
  func populateHintMatches(_ state: inout CopyModeState, source: HintSource, reader: TerminalContentReading)

  /// Extract selected text (visual/line/block) for the current selection.
  /// Pure mapping coords→text; caller writes the pasteboard.
  func yankText(_ state: CopyModeState, reader: TerminalContentReading) -> String?

  /// scroll-to-bottom on exit (binding action).
  func scrollToBottom(reader: TerminalContentReading)

  /// The full per-keystroke switch. Mutates state; performs pasteboard /
  /// open side-effects; returns whether the caller consumes / passes through
  /// / ends copy mode. `config` is captured once by the caller.
  func handleKey(
    key: Character, keyStr: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
    state: inout CopyModeState, config: Config, reader: TerminalContentReading) -> KeyResult
}
```

Move the bodies VERBATIM (search/scroll/yank/hint/key-switch from ContentView lines 1028-1078 entry logic, 1086-1115 scroll, 1479-1655 search/read/hint/yank, 1197-1359 key switch), substituting `reader` for `pane.surfaceView` and reading lines via `reader.readRow(...)`/`readText(...)`. `readLineByScreenRow`/`readTerminalLine`/`readScreenLine`/`scanViewportForHints` become private helpers on the controller taking `reader`. The `.enterHintMode` and scrolloff config reads use `config` passed in (resolved once by the caller via the same `MisttyConfig.load()`/`.current` calls — config can't change within one keystroke, so this is behavior-equivalent).

- [ ] Write `MisttyTests/Models/CopyModeControllerTests.swift` with a `FakeTerminalContent: TerminalContentReading` (canned rows, settable scrollbar, records binding actions). Cover, at minimum:
  - `makeInitialState`: scrollback-anchored cursor goes mid-viewport; live-edge cursor uses `cursorPosition()`.
  - `scrollViewport`: offset clamps at 0 and at `total-len`; returns actual delta; anchor shifts by actual delta not requested.
  - `runSearch` forward/reverse: cursor lands on the right match, index/total set, wrap-around.
  - `yankText`: visual / visualLine / visualBlock produce expected substrings from canned rows.
- [ ] Red (no controller) → implement → green. Build + full suite at baseline.
- [ ] Commit: `feat(copy-mode): extract CopyModeController over TerminalContentReading`.

---

### Task 3: Wire ContentView to the controller; delete the duplicated code

**Files:** `Mistty/App/ContentView.swift`.

- [ ] Add `private let copyModeController = CopyModeController()` (or `@State`); the monitor closure and handlers call it.
- [ ] `enterCopyMode`: keep the window-mode-exit side effect + pane lookup; replace the dimension/cursor/pin/state-construction body with `activePane.copyModeState = copyModeController.makeInitialState(reader: activePane.surfaceView)`.
- [ ] `exitCopyMode`: `copyModeController.scrollToBottom(reader:)` + clear state.
- [ ] `handleYankHints`: keep pane lookup + state write-back; resolve `Config` from `MisttyConfig.load()`; call `copyModeController.populateHintMatches`.
- [ ] `installCopyModeMonitor`: keep the monitor + `isActiveTerminalWindow` guard + pane/keyStr extraction; resolve `config` once; call `controller.handleKey(...)`; map `KeyResult` → return `event`/`nil` and write `copyModeState`/clear on `.exit`.
- [ ] DELETE from ContentView: `scrollViewport`, `runSearch`, `readTerminalLine`, `readLineByScreenRow`, `readScreenLine`, `scanViewportForHints`, `populateHintMatches`, `yankSelection`, and the inline entry/scroll/switch bodies now living in the controller. KEEP: `copyModePane`, `handleCopyMode`, the hint-modifier monitor + `reconcileHintShiftHeld`/`clearHintShiftHeld` (they mutate `pane.copyModeState.hint` directly — small, view-coupled, leave for now).
- [ ] Build + full suite at baseline. Acceptance grep: `grep -cE "ghostty_surface_(binding_action|pin_viewport|read_text|size)" Mistty/App/ContentView.swift` → 0 (all surface C calls now go through the surface view / controller).
- [ ] Commit: `refactor(copy-mode): route ContentView through CopyModeController`.

---

### Final verification
- [ ] Full suite baseline-only; CopyModeControllerTests green. If running the app is convenient: enter copy mode, `/`-search, `n`/`N`, visual-line yank, hint copy — all behave as before.
