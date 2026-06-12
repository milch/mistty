# Audit Fixes Wave 2: Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the hot-path waste found by the 2026-06 performance audit: per-keystroke full-scrollback FFI scans in copy-mode search, app-wide notification spam from scrollbar events, per-keypress process-tree syscall walks, per-mutation restorable-state invalidation, per-character NSString allocations in hint scanning, and per-line FileHandle churn in DebugLog.

**Architecture:** One new pure-logic file (`Mistty/Models/SearchMatching.swift`) carries the testable search-match arithmetic; everything else is a local change to an existing file. No behavior changes except: search match-position caching means matches are recomputed when the query or scrollback row count changes (not on every n/N press), and scrollbar-change notifications are only posted while the emitting pane is hinting (its only consumer).

**Tech Stack:** Swift / SwiftPM, XCTest. Same verification commands as Wave 1:
- Full suite: `swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log` (23 `ChromePolishSnapshotTests` failures are a known pre-existing environment-dependent baseline — ignore them; anything else is a regression)
- Filtered: `swift test --skip Benchmark --filter <ClassName> 2>&1 | tee /tmp/mistty-test.log`
- Build: `swift build 2>&1 | tee /tmp/mistty-build.log`

---

### Task 1: Single-pass, cached copy-mode search

**Files:**
- Create: `Mistty/Models/SearchMatching.swift`
- Modify: `Mistty/Models/CopyModeState.swift:38` (add cache fields after `scrollGeneration`)
- Modify: `Mistty/App/ContentView.swift` — replace `performSearch` (≈line 1541), `findMatchOnLine` (≈1602), `countSearchMatches` (≈1625) with one `runSearch`; update the three call sites in the copy-mode key handler (≈lines 1320-1331)
- Test: Create `MisttyTests/Models/SearchMatchingTests.swift`

**Background:** Every `n`/`N`/confirm currently runs `performSearch` AND `countSearchMatches`, each iterating the entire scrollback (`scrollbar.total`, potentially tens of thousands of rows) with one `ghostty_surface_read_text` FFI round-trip + String allocation per row — synchronously on the main thread, twice per keypress. Fix: scan once per (query, totalRows), store matches in `CopyModeState`, and derive both the jump target and the index/total display from the cached array with pure logic.

**Semantics to preserve (from the current code):**
- Forward (`n`): first match strictly after the cursor in reading order, wrapping cyclically.
- Reverse (`N`): last match strictly before the cursor, wrapping cyclically.
- After a jump, `searchMatchIndex` is the 1-based position of the landed-on match; `searchMatchTotal` is the total count. No matches anywhere → both nil, cursor unmoved.
- The match scroll centers the target row in the viewport and synchronously front-runs the async scrollbar callback (`scrollbarState.offset` write) so consecutive `n` presses compute correct coordinates.

- [ ] **Step 1: Write the failing tests**

Create `MisttyTests/Models/SearchMatchingTests.swift`:

```swift
import XCTest

@testable import Mistty

/// Pure-logic tests for copy-mode search-match arithmetic. The FFI scan
/// that produces the `[SearchMatch]` array lives in ContentView (untestable
/// without a live surface); this covers the jump-target and index math
/// that used to be interleaved with the scan loops.
final class SearchMatchingTests: XCTestCase {
  // Sorted by (row, col), as the scanner produces them.
  private let matches = [
    SearchMatch(row: 2, col: 4),
    SearchMatch(row: 2, col: 9),
    SearchMatch(row: 5, col: 0),
    SearchMatch(row: 9, col: 7),
  ]

  func test_nextMatch_forward_findsFirstAfterCursor() {
    let m = SearchMatching.nextMatch(after: 2, col: 4, in: matches, forward: true)
    XCTAssertEqual(m, SearchMatch(row: 2, col: 9))
  }

  func test_nextMatch_forward_skipsMatchAtCursor() {
    // A match exactly at the cursor must not be returned (n moves on).
    let m = SearchMatching.nextMatch(after: 5, col: 0, in: matches, forward: true)
    XCTAssertEqual(m, SearchMatch(row: 9, col: 7))
  }

  func test_nextMatch_forward_wrapsPastEnd() {
    let m = SearchMatching.nextMatch(after: 9, col: 7, in: matches, forward: true)
    XCTAssertEqual(m, SearchMatch(row: 2, col: 4))
  }

  func test_nextMatch_reverse_findsLastBeforeCursor() {
    let m = SearchMatching.nextMatch(after: 5, col: 0, in: matches, forward: false)
    XCTAssertEqual(m, SearchMatch(row: 2, col: 9))
  }

  func test_nextMatch_reverse_wrapsPastStart() {
    let m = SearchMatching.nextMatch(after: 2, col: 4, in: matches, forward: false)
    XCTAssertEqual(m, SearchMatch(row: 9, col: 7))
  }

  func test_nextMatch_emptyMatches_returnsNil() {
    XCTAssertNil(SearchMatching.nextMatch(after: 0, col: 0, in: [], forward: true))
    XCTAssertNil(SearchMatching.nextMatch(after: 0, col: 0, in: [], forward: false))
  }

  func test_index_isOneBasedPositionInSortedOrder() {
    XCTAssertEqual(SearchMatching.index(of: SearchMatch(row: 2, col: 4), in: matches), 1)
    XCTAssertEqual(SearchMatching.index(of: SearchMatch(row: 9, col: 7), in: matches), 4)
    XCTAssertNil(SearchMatching.index(of: SearchMatch(row: 0, col: 0), in: matches))
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --skip Benchmark --filter SearchMatchingTests 2>&1 | tee /tmp/mistty-test.log`
Expected: compile FAILURE — `cannot find 'SearchMatch' in scope`.

- [ ] **Step 3: Implement `SearchMatching`**

Create `Mistty/Models/SearchMatching.swift`:

```swift
import Foundation

/// One search hit in SCREEN coordinates (row 0 = top of scrollback).
struct SearchMatch: Equatable {
  var row: Int
  var col: Int
}

/// Pure jump-target / index arithmetic over a sorted match list. The
/// expensive part of search — reading scrollback lines over FFI — happens
/// once per (query, row-count) in ContentView and is cached in
/// `CopyModeState.searchMatches`; n/N presses only run this logic.
enum SearchMatching {
  /// First match strictly after (forward) or last match strictly before
  /// (reverse) the given position, wrapping cyclically. `matches` must be
  /// sorted by (row, col).
  static func nextMatch(
    after row: Int, col: Int, in matches: [SearchMatch], forward: Bool
  ) -> SearchMatch? {
    guard !matches.isEmpty else { return nil }
    if forward {
      return matches.first { $0.row > row || ($0.row == row && $0.col > col) }
        ?? matches.first
    } else {
      return matches.last { $0.row < row || ($0.row == row && $0.col < col) }
        ?? matches.last
    }
  }

  /// 1-based position of `match` in the sorted list (what the `[3/17]`
  /// toast shows), or nil if it isn't present.
  static func index(of match: SearchMatch, in matches: [SearchMatch]) -> Int? {
    guard let i = matches.firstIndex(of: match) else { return nil }
    return i + 1
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --skip Benchmark --filter SearchMatchingTests 2>&1 | tee /tmp/mistty-test.log`
Expected: 7 tests PASS.

- [ ] **Step 5: Add the cache fields to `CopyModeState`**

In `Mistty/Models/CopyModeState.swift`, directly after the `scrollGeneration` property (line 38), add:

```swift
  /// Cached search-match positions in SCREEN coordinates, sorted by
  /// (row, col). Rebuilt by ContentView's `runSearch` when the query or
  /// the scrollback row count changes — n/N presses reuse the cache
  /// instead of re-reading the entire scrollback over FFI twice per
  /// keypress. `searchMatchesQuery`/`searchMatchesTotalRows` are the
  /// cache key.
  var searchMatches: [SearchMatch] = []
  var searchMatchesQuery: String?
  var searchMatchesTotalRows: Int = 0
```

- [ ] **Step 6: Replace the ContentView search functions**

In `Mistty/App/ContentView.swift`, DELETE these three private functions entirely: `performSearch(_:direction:)` (starts ≈line 1541, the one guarded by `!state.searchQuery.isEmpty` that loops `for i in 0...totalRows`), `findMatchOnLine(_:query:cursorCol:forward:)` (≈1602), and `countSearchMatches(_:)` (≈1625). In their place add:

```swift
  /// One search pass per (query, scrollback-size): scans every screen row
  /// once into `state.searchMatches`, then derives both the jump target
  /// and the [index/total] display from the cached array. Previously
  /// `performSearch` + `countSearchMatches` EACH scanned the entire
  /// scrollback (one `ghostty_surface_read_text` FFI call + String
  /// allocation per row) on every n/N/confirm keypress.
  private func runSearch(_ state: inout CopyModeState, direction: SearchDirection) {
    guard !state.searchQuery.isEmpty,
      let pane = copyModePane,
      let surface = pane.surfaceView.surface
    else { return }

    let scrollbar = pane.surfaceView.scrollbarState
    let totalRows = Int(scrollbar.total)
    guard totalRows > 0 else { return }
    let cols = Int(ghostty_surface_size(surface).columns)

    if state.searchMatchesQuery != state.searchQuery
      || state.searchMatchesTotalRows != totalRows
    {
      var matches: [SearchMatch] = []
      for row in 0..<totalRows {
        guard let line = readLineByScreenRow(row) else { continue }
        var searchStart = line.startIndex
        while let range = line.range(
          of: state.searchQuery, options: .caseInsensitive,
          range: searchStart..<line.endIndex)
        {
          matches.append(SearchMatch(
            row: row, col: line.distance(from: line.startIndex, to: range.lowerBound)))
          searchStart = range.upperBound
        }
      }
      state.searchMatches = matches
      state.searchMatchesQuery = state.searchQuery
      state.searchMatchesTotalRows = totalRows
    }

    let cursorScreenRow = state.cursorRow + Int(scrollbar.offset)
    guard let target = SearchMatching.nextMatch(
      after: cursorScreenRow, col: state.cursorCol,
      in: state.searchMatches, forward: direction == .forward)
    else {
      state.searchMatchTotal = nil
      state.searchMatchIndex = nil
      return
    }

    // Scroll to make the match visible — center it in viewport.
    let viewportRows = Int(scrollbar.len)
    let targetOffset = max(0, min(target.row - viewportRows / 2, totalRows - viewportRows))
    let actionStr = "scroll_to_row:\(targetOffset)"
    _ = ghostty_surface_binding_action(surface, actionStr, UInt(actionStr.utf8.count))

    // Update scrollbar state synchronously — the async callback will
    // eventually arrive with the same value, but we need it now for
    // subsequent searches (n/N) to compute correct screen coordinates.
    pane.surfaceView.scrollbarState.offset = UInt64(targetOffset)

    state.cursorRow = target.row - targetOffset
    state.cursorCol = min(target.col, cols - 1)
    state.desiredCol = nil
    state.searchMatchTotal = state.searchMatches.count
    state.searchMatchIndex = SearchMatching.index(of: target, in: state.searchMatches)
  }
```

Then update the three call sites in the copy-mode key handler (≈lines 1320-1331). Replace:

```swift
        case .confirmSearch:
          self.performSearch(&copyState, direction: copyState.searchDirection)
          self.countSearchMatches(&copyState)
        case .cancelSearch:
          break  // Already handled in copyState
        case .searchNext:
          self.performSearch(&copyState, direction: copyState.searchDirection)
          self.countSearchMatches(&copyState)
        case .searchPrev:
          let reversed: SearchDirection = copyState.searchDirection == .forward ? .reverse : .forward
          self.performSearch(&copyState, direction: reversed)
          self.countSearchMatches(&copyState)
```

with:

```swift
        case .confirmSearch:
          self.runSearch(&copyState, direction: copyState.searchDirection)
        case .cancelSearch:
          break  // Already handled in copyState
        case .searchNext:
          self.runSearch(&copyState, direction: copyState.searchDirection)
        case .searchPrev:
          let reversed: SearchDirection = copyState.searchDirection == .forward ? .reverse : .forward
          self.runSearch(&copyState, direction: reversed)
```

- [ ] **Step 7: Build and run the full suite**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log`
Expected: build PASS; only the 23 known ChromePolish snapshot failures. `CopyModeStateTests` and `CopyModeIntegrationTests` must pass untouched (they exercise the state machine, not the ContentView scan).

- [ ] **Step 8: Commit**

```bash
git add Mistty/Models/SearchMatching.swift Mistty/Models/CopyModeState.swift Mistty/App/ContentView.swift MisttyTests/Models/SearchMatchingTests.swift
git commit -m "perf(copy-mode): single cached search pass instead of two full scans per keypress

performSearch + countSearchMatches each iterated the entire scrollback
(one read_text FFI call + String alloc per row) on every n/N/confirm.
Scan once per (query, row count) into CopyModeState.searchMatches and
derive the jump target and [index/total] from the cached array with
pure, tested logic (SearchMatching).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Post `.misttyScrollChanged` only while the emitting pane is hinting

**Files:**
- Modify: `Mistty/App/GhosttyApp.swift` — the `GHOSTTY_ACTION_SCROLLBAR` case inside `actionCallback`

**Background:** libghostty emits scrollbar updates continuously during output — thousands per second during a fast `cat`/build. Each one currently posts `.misttyScrollChanged` app-wide. The notification's ONLY consumer (verified by grep: `ContentView.swift:91`) immediately guards on `copyState.isHinting` — so during normal output every post is pure overhead delivered to every window. Gate the post on the emitting pane's own hinting state; the scrollbarState write stays unconditional. Build + full suite verified.

- [ ] **Step 1: Gate the notification**

In `Mistty/App/GhosttyApp.swift`, in the `GHOSTTY_ACTION_SCROLLBAR` case, the main-queue block currently reads (post-Wave-1 code):

```swift
      DispatchQueue.main.async {
        let view = unmanagedView.takeRetainedValue()
        view.scrollbarState = ScrollbarState(total: sb.total, offset: sb.offset, len: sb.len)
        // If copy mode is hinting, re-scan labels after mouse/wheel scroll.
        NotificationCenter.default.post(name: .misttyScrollChanged, object: nil)
      }
```

Replace it with:

```swift
      DispatchQueue.main.async {
        let view = unmanagedView.takeRetainedValue()
        view.scrollbarState = ScrollbarState(total: sb.total, offset: sb.offset, len: sb.len)
        // This action fires for every output chunk (thousands/sec during a
        // fast build) and was broadcast app-wide. Its only consumer is the
        // copy-mode hint rescan, which no-ops unless the pane is hinting —
        // so skip the post unless the emitting pane is actually hinting.
        if view.pane?.copyModeState?.isHinting == true {
          NotificationCenter.default.post(name: .misttyScrollChanged, object: nil)
        }
      }
```

- [ ] **Step 2: Build and run the full suite**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log`
Expected: build PASS; only the 23 known snapshot failures.

- [ ] **Step 3: Commit**

```bash
git add Mistty/App/GhosttyApp.swift
git commit -m "perf(ghostty): only broadcast scrollbar changes while hinting

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: TTL-cache `MisttyPane.isInRemoteShell`

**Files:**
- Modify: `Mistty/Models/MisttyPane.swift:75-78` (`isInRemoteShell`)

**Background:** `isInRemoteShell` runs the full foreground-process syscall walk (`tcgetpgrp` + `proc_listpids` + per-member `proc_pidpath`/`KERN_PROCARGS2`). The ctrl-hjkl nav monitor evaluates it per keypress — including ~30 Hz autorepeat — whenever neovim is in the foreground (`ContentView.swift`, `pane.isRunningNeovim && !pane.isInRemoteShell`). Foreground-process changes are human-timescale; cache the verdict for 2 seconds. Build-verified (the resolver is not injectable on `MisttyPane`; the cache is a pure pass-through otherwise).

- [ ] **Step 1: Add the cache**

In `Mistty/Models/MisttyPane.swift`, replace the `isInRemoteShell` computed property (lines 75-78, keep its existing doc comment above it) with:

```swift
  var isInRemoteShell: Bool {
    // Resolving the foreground process is a multi-syscall walk (tcgetpgrp,
    // proc_listpids, per-member describe). The ctrl-hjkl nav monitor reads
    // this per keypress (incl. autorepeat) while nvim is focused, so cache
    // the verdict briefly — foreground-process churn is human-timescale.
    let now = ContinuousClock.now
    if let cached = remoteShellCache, now - cached.at < .seconds(2) {
      return cached.value
    }
    let value: Bool
    if let fp = ForegroundProcessResolver.current(for: self) {
      value = ForegroundProcessResolver.remoteShellExecutables.contains(fp.executable)
    } else {
      value = false
    }
    remoteShellCache = (value, now)
    return value
  }

  @ObservationIgnored
  private var remoteShellCache: (value: Bool, at: ContinuousClock.Instant)?
```

- [ ] **Step 2: Build and run the model tests**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark --filter MisttyPaneTests 2>&1 | tee /tmp/mistty-test.log`
Expected: build PASS, MisttyPaneTests PASS.

- [ ] **Step 3: Commit**

```bash
git add Mistty/Models/MisttyPane.swift
git commit -m "perf(pane): cache isInRemoteShell verdict for 2s

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Debounce restorable-state invalidation

**Files:**
- Modify: `Mistty/Services/StateRestorationObserver.swift:13-22` (`reobserve`)

**Background:** `reobserve`'s `onChange` fires on EVERY mutation of any tracked field — including split-ratio changes on every divider-drag tick and per-command `currentWorkingDirectory`/title updates — each time re-walking the whole model in `snapshotKeys()` and calling `invalidateRestorableState()`. Re-arm observation immediately (no mutation may be missed) but trail-debounce the invalidation by 1 s. Build-verified.

- [ ] **Step 1: Add the debounce**

In `Mistty/Services/StateRestorationObserver.swift`, add a stored property after `let windowsStore: WindowsStore`:

```swift
  /// Trailing debounce for invalidation. A divider drag mutates layout
  /// ratios on every tick and each mutation re-fires onChange; observation
  /// is re-armed immediately (so no mutation is missed) but the
  /// invalidateRestorableState calls are coalesced — the eventual
  /// restorable-state encode walks every pane's foreground process tree.
  private var pendingInvalidation: DispatchWorkItem?
```

and replace `reobserve()` (lines 13-22) with:

```swift
  private func reobserve() {
    withObservationTracking {
      _ = snapshotKeys()
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.reobserve()
        self.pendingInvalidation?.cancel()
        let work = DispatchWorkItem { NSApp?.invalidateRestorableState() }
        self.pendingInvalidation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
      }
    }
  }
```

- [ ] **Step 2: Build and run the full suite**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log`
Expected: build PASS; only the 23 known snapshot failures.

- [ ] **Step 3: Commit**

```bash
git add Mistty/Services/StateRestorationObserver.swift
git commit -m "perf(restore): debounce restorable-state invalidation by 1s

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `HintDetector.lineMatch` without per-character NSString allocations

**Files:**
- Modify: `Mistty/Models/HintDetector.swift:30-54` (`lineMatch`)
- Test: `MisttyTests/Models/HintDetectorTests.swift`

**Background:** `lineMatch` trims whitespace by allocating an NSString per character (`ns.substring(with: NSRange(location: i, length: 1))`) — up to ~10k tiny allocations per viewport scan in line-hint mode, re-run on every scroll event while hinting. Note on TDD shape: the new tests are *characterization* tests — they pin the current behavior and should PASS against the old implementation too (run them once before changing code to prove that); the implementation swap must keep them green.

- [ ] **Step 1: Write the characterization tests**

Add to `MisttyTests/Models/HintDetectorTests.swift`:

```swift
  // MARK: - Line source (characterization for the allocation-free rewrite)

  func test_lineSource_skipsWhitespaceOnlyAndEmptyLines() {
    let m = HintDetector.detect(lines: ["   ", "\t\t", ""], source: .lines)
    XCTAssertTrue(m.isEmpty)
  }

  func test_lineSource_keepsLeadingWhitespace_trimsTrailing() {
    let m = HintDetector.detect(lines: ["  hello world   "], source: .lines)
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].text, "  hello world")
    XCTAssertEqual(m[0].kind, .line)
    XCTAssertEqual(m[0].range.startCol, 0)
    XCTAssertEqual(m[0].range.endCol, 12)
  }

  func test_lineSource_rowIndexPreserved() {
    let m = HintDetector.detect(lines: ["first", "", "third"], source: .lines)
    // detect() sorts bottom-to-top.
    XCTAssertEqual(m.map(\.range.startRow), [2, 0])
    XCTAssertEqual(m.map(\.text), ["third", "first"])
  }
```

- [ ] **Step 2: Run them against the OLD implementation**

Run: `swift test --skip Benchmark --filter HintDetectorTests 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS (these pin existing behavior — if any fails, STOP and re-check the test against the old code rather than proceeding).

- [ ] **Step 3: Swap the implementation**

In `Mistty/Models/HintDetector.swift`, replace `lineMatch` (lines 30-54) with:

```swift
  private static func lineMatch(line: String, row: Int) -> HintMatch? {
    // Single backward pass, no per-character NSString allocations — the
    // old substring(with:)-per-character trim ran for every viewport row
    // on every hint rescan (each scroll event while hinting).
    guard let lastIdx = line.lastIndex(where: { !$0.isWhitespace }) else {
      return nil  // all-whitespace (or empty) line
    }
    // Include leading whitespace in text and pill starts at column 0.
    let text = String(line[...lastIdx])
    let endCol = text.utf16.count - 1
    return HintMatch(
      range: HintRange(startRow: row, startCol: 0, endRow: row, endCol: endCol),
      text: text,
      kind: .line
    )
  }
```

- [ ] **Step 4: Run the tests to verify they still pass**

Run: `swift test --skip Benchmark --filter HintDetectorTests 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS — all existing pattern tests plus the three new line-source tests.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/HintDetector.swift MisttyTests/Models/HintDetectorTests.swift
git commit -m "perf(hints): allocation-free whitespace trim in lineMatch

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Keep the DebugLog file handle open

**Files:**
- Modify: `Mistty/Support/DebugLog.swift:46-59` (`append`)

**Background:** Each log line opens, seeks, writes, and closes a `FileHandle` (4+ syscalls) on the main actor. Off by default, so impact is opt-in — but the fix is trivial. Build-verified.

- [ ] **Step 1: Persist the handle**

In `Mistty/Support/DebugLog.swift`, add a stored property after `private(set) var isEnabled: Bool = false`:

```swift
  /// Kept open across appends — opening/seeking/closing a FileHandle per
  /// log line is 4+ syscalls each, on the main actor. Reset to nil on a
  /// write error so the next append re-opens (e.g. log file deleted).
  private var handle: FileHandle?
```

and replace `append` (lines 46-59) with:

```swift
  private func append(_ raw: String) {
    var line = raw
    if !line.hasSuffix("\n") { line += "\n" }
    guard let data = line.data(using: .utf8) else { return }
    if handle == nil {
      if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
      }
      handle = try? FileHandle(forWritingTo: logURL)
      _ = try? handle?.seekToEnd()
    }
    guard let handle else { return }
    do {
      try handle.write(contentsOf: data)
    } catch {
      // Underlying file vanished or fd went bad — drop the handle so the
      // next append re-creates and re-opens.
      try? handle.close()
      self.handle = nil
    }
  }
```

- [ ] **Step 2: Build and run the full suite**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log && swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log`
Expected: build PASS; only the 23 known snapshot failures.

- [ ] **Step 3: Commit**

```bash
git add Mistty/Support/DebugLog.swift
git commit -m "perf(debuglog): keep log file handle open across appends

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Final verification

- [ ] Full suite: `swift test --skip Benchmark 2>&1 | tee /tmp/mistty-test.log` — only the 23 known `ChromePolishSnapshotTests` failures.
- [ ] `git log --oneline` shows one commit per task.

## Explicitly deferred (not in this wave)

- **Search/selection overlay viewport snapshots** (`SearchHighlightView`/`SelectionHighlightView` re-read the viewport per Canvas redraw): deferred to Wave 4 — the `CopyModeController` extraction restructures exactly this code path around a content-reading protocol, and a stable "current match" input is entangled with UX semantics.
- **`takeSnapshot` foreground-process walk off the main thread**: the Task 4 debounce reduces trigger frequency; moving the walk off-main needs the Wave 4 concurrency story.
- **IPC semaphore → async continuation**: belongs to the Wave 3/4 IPC protocol rework.
- **`scrollMultiplier` config read per scroll-wheel event**: measured as retain/release churn only; not worth touching the surface view for.
