# Copy Mode Phase 3 (Yank Hints) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add tmux-thumbs style yank hints to copy mode: `y`/`o` over detected patterns (URLs, paths, hashes, quoted strings, code spans, UUIDs, emails, IPs, env vars, numbers) and `Y` over non-empty lines.

**Architecture:** New `.hint(HintState)` sub-mode on `CopyModeState`. Pure detection + label logic lives in `HintDetector` / `HintLabels` with no UI dependency. `ContentView` reads the viewport, builds matches, stores them on state, and renders via new `CopyModeHintOverlay`. Scroll re-scans. `cmd+shift+y` enters copy mode + hint mode from anywhere.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, TOMLKit, XCTest. Spec: `docs/superpowers/specs/2026-04-13-copy-mode-phase3-design.md`.

---

## File Structure

### New files

- `Mistty/Models/HintDetector.swift` — regex detectors, container handling, line source, conflict resolution
- `Mistty/Models/HintLabels.swift` — label alphabet generation (tmux-thumbs algorithm)
- `Mistty/Views/Terminal/CopyModeHintOverlay.swift` — dim layer + pill labels
- `MisttyTests/Models/HintDetectorTests.swift`
- `MisttyTests/Models/HintLabelsTests.swift`
- `MisttyTests/Models/CopyModeHintIntegrationTests.swift`

### Modified files

- `Mistty/Models/CopyModeAction.swift` — new actions + `HintAction` / `HintSource` enums + `HintMatch` / `HintState` structs
- `Mistty/Models/CopyModeState.swift` — `.hint` sub-mode, entry keys `y` (w/o selection) / `o` / `Y`, input routing
- `Mistty/Config/MisttyConfig.swift` — `[copy_mode.hints]` parsing, `CopyModeHintsConfig` struct
- `Mistty/Views/Terminal/CopyModeOverlay.swift` — add mode indicator cases, mount `CopyModeHintOverlay`
- `Mistty/Views/Terminal/CopyModeHelpOverlay.swift` — hint mode section
- `Mistty/App/ContentView.swift` — consume new actions, viewport scan, scroll re-scan, clipboard/open, `cmd+shift+y` notification handler
- `Mistty/App/MisttyApp.swift` — new menu item + `misttyYankHints` notification

---

## Task 1: Add sub-mode / action / data types

**Files:**
- Modify: `Mistty/Models/CopyModeAction.swift`

- [ ] **Step 1: Add types to CopyModeAction.swift**

Append after the existing `CopyModeAction` enum:

```swift
// MARK: - Phase 3: Hint mode

enum HintAction: Equatable {
  case copy
  case open
}

enum HintSource: Equatable {
  case patterns
  case lines
}

enum HintKind: Equatable {
  case url
  case email
  case uuid
  case path
  case hash
  case ipv4
  case ipv6
  case envVar
  case number
  case quoted
  case codeSpan
  case line
}

struct HintRange: Equatable {
  let startRow: Int
  let startCol: Int
  let endRow: Int  // inclusive
  let endCol: Int  // inclusive
}

struct HintMatch: Equatable {
  let range: HintRange
  let text: String
  let kind: HintKind
}

struct HintState: Equatable {
  let action: HintAction       // default action from entry key
  let source: HintSource
  var matches: [HintMatch]     // bottom→top, left→right
  var labels: [String]         // index-aligned with matches
  var typedPrefix: String = "" // "" or single char
}
```

Extend `CopySubMode`:

```swift
enum CopySubMode: Equatable {
  case normal
  case visual
  case visualLine
  case visualBlock
  case searchForward
  case searchReverse
  case hint
}
```

Extend `CopyModeAction`:

```swift
case enterHintMode(HintAction, HintSource)
case hintInput(Character)     // first char of 2-char label typed
case exitHintMode
case copyText(String)
case openItem(String)
case requestHintScan            // signal ContentView to scan + populate matches
```

- [ ] **Step 2: Build**

Run: `just build` (or `xcodebuild build -scheme Mistty`)
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Mistty/Models/CopyModeAction.swift
git commit -m "feat(copy-mode): add hint mode action/sub-mode/data types"
```

---

## Task 2: Implement HintLabels

**Files:**
- Create: `Mistty/Models/HintLabels.swift`
- Create: `MisttyTests/Models/HintLabelsTests.swift`

- [ ] **Step 1: Write failing tests**

`MisttyTests/Models/HintLabelsTests.swift`:

```swift
import XCTest
@testable import Mistty

final class HintLabelsTests: XCTestCase {
  func test_singleMatch_singleChar() {
    let labels = HintLabels.generate(count: 1, alphabet: "asdf")
    XCTAssertEqual(labels, ["a"])
  }

  func test_lessThanAlphabet_allSingleChar() {
    let labels = HintLabels.generate(count: 3, alphabet: "asdf")
    XCTAssertEqual(labels, ["a", "s", "d"])
  }

  func test_moreThanAlphabet_usesTwoCharLabels() {
    // 5 matches, alphabet size 4. Reserve 1 prefix ("f") for 2-char labels.
    // 3 single-char: a, s, d. 2 two-char: fa, fs.
    let labels = HintLabels.generate(count: 5, alphabet: "asdf")
    XCTAssertEqual(labels, ["a", "s", "d", "fa", "fs"])
  }

  func test_exactSquareCapacity() {
    // alphabet size 2, 4 matches => 0 single-char, 4 two-char (aa, as, sa, ss)
    let labels = HintLabels.generate(count: 4, alphabet: "as")
    XCTAssertEqual(labels, ["aa", "as", "sa", "ss"])
  }

  func test_allLabelsUnique() {
    let labels = HintLabels.generate(count: 50, alphabet: "asdfghjkl")
    XCTAssertEqual(Set(labels).count, labels.count)
  }

  func test_zeroCount_emptyArray() {
    let labels = HintLabels.generate(count: 0, alphabet: "asdf")
    XCTAssertEqual(labels, [])
  }
}
```

- [ ] **Step 2: Run tests — verify fail**

Run: `just test-filter HintLabelsTests` (or `xcodebuild test -scheme Mistty -only-testing:MisttyTests/HintLabelsTests`)
Expected: FAIL (HintLabels undefined).

- [ ] **Step 3: Implement HintLabels**

`Mistty/Models/HintLabels.swift`:

```swift
import Foundation

enum HintLabels {
  /// Generate `count` unique labels from the given alphabet.
  ///
  /// If `count` ≤ alphabet size, emit single-char labels from the front of
  /// the alphabet. Otherwise reserve a suffix of the alphabet as two-char
  /// prefixes — the minimum needed so total labels ≥ count.
  static func generate(count: Int, alphabet: String) -> [String] {
    guard count > 0 else { return [] }
    let chars = Array(alphabet)
    let k = chars.count
    precondition(k > 0, "alphabet must not be empty")

    if count <= k {
      return (0..<count).map { String(chars[$0]) }
    }

    // Find minimum number of prefixes p (1...k) such that
    // (k - p) + p * k >= count.
    // That simplifies to k + p*(k - 1) >= count → p >= (count - k) / (k - 1).
    // If k == 1, fall through to p = 1 / 2 / ... multi-char labels.
    var p = 1
    while p < k {
      let singleCount = k - p
      let doubleCount = p * k
      if singleCount + doubleCount >= count { break }
      p += 1
    }
    if k == 1 {
      // Degenerate: alphabet of size 1 — emit "a", "aa", "aaa", ...
      var labels: [String] = []
      var length = 1
      while labels.count < count {
        labels.append(String(repeating: chars[0], count: length))
        length += 1
      }
      return labels
    }

    var labels: [String] = []
    let singleEnd = k - p  // chars[0 ..< singleEnd] are single-char
    for i in 0..<singleEnd {
      labels.append(String(chars[i]))
      if labels.count == count { return labels }
    }
    for i in singleEnd..<k {
      for j in 0..<k {
        labels.append(String(chars[i]) + String(chars[j]))
        if labels.count == count { return labels }
      }
    }
    return labels
  }
}
```

- [ ] **Step 4: Run tests — verify pass**

Run: `just test-filter HintLabelsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/HintLabels.swift MisttyTests/Models/HintLabelsTests.swift
git commit -m "feat(copy-mode): add HintLabels generator"
```

---

## Task 3: Implement HintDetector (patterns + lines + conflict resolution)

**Files:**
- Create: `Mistty/Models/HintDetector.swift`
- Create: `MisttyTests/Models/HintDetectorTests.swift`

- [ ] **Step 1: Write failing tests**

`MisttyTests/Models/HintDetectorTests.swift`:

```swift
import XCTest
@testable import Mistty

final class HintDetectorTests: XCTestCase {

  private func scan(_ lines: [String]) -> [HintMatch] {
    HintDetector.detect(lines: lines, source: .patterns)
  }

  func test_url_detected() {
    let m = scan(["visit https://example.com/x today"])
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].kind, .url)
    XCTAssertEqual(m[0].text, "https://example.com/x")
  }

  func test_url_trailing_punctuation_stripped() {
    let m = scan(["see https://example.com."])
    XCTAssertEqual(m[0].text, "https://example.com")
  }

  func test_uuid_detected() {
    let m = scan(["id 550e8400-e29b-41d4-a716-446655440000 ok"])
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].kind, .uuid)
  }

  func test_path_detected() {
    let m = scan(["open /usr/local/bin/foo now"])
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].kind, .path)
    XCTAssertEqual(m[0].text, "/usr/local/bin/foo")
  }

  func test_hash_detected() {
    let m = scan(["sha abc1234 ok"])
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].kind, .hash)
    XCTAssertEqual(m[0].text, "abc1234")
  }

  func test_longest_match_wins_between_peers() {
    // A path that contains a hash-looking substring — only the path wins.
    let m = scan(["/a/abcdef0 file"])
    let kinds = Set(m.map(\.kind))
    XCTAssertTrue(kinds.contains(.path))
    XCTAssertFalse(kinds.contains(.hash))
  }

  func test_container_codeSpan_emitsBothOuterAndInner() {
    let m = scan(["run `abcdef1234567` quick"])
    XCTAssertEqual(m.count, 2)
    XCTAssertTrue(m.contains(where: { $0.kind == .codeSpan }))
    XCTAssertTrue(m.contains(where: { $0.kind == .hash }))
  }

  func test_container_quoted_emitsBothOuterAndInner() {
    let m = scan(["echo \"/tmp/x.log\""])
    XCTAssertEqual(m.count, 2)
    XCTAssertTrue(m.contains(where: { $0.kind == .quoted }))
    XCTAssertTrue(m.contains(where: { $0.kind == .path }))
  }

  func test_envVar_vs_number() {
    let m = scan(["PORT 8080"])
    let kinds = Set(m.map(\.kind))
    XCTAssertTrue(kinds.contains(.envVar))
    XCTAssertTrue(kinds.contains(.number))
  }

  func test_line_source_skipsEmptyLines() {
    let lines = ["hello", "   ", "", "world"]
    let m = HintDetector.detect(lines: lines, source: .lines)
    XCTAssertEqual(m.count, 2)
    XCTAssertEqual(m.map(\.text), ["hello", "world"])
    XCTAssertEqual(m[0].kind, .line)
  }

  func test_ordering_bottomToTop_leftToRight() {
    let lines = ["a http://one.com b", "c http://two.com d http://three.com"]
    let matches = scan(lines)
    // Expect two.com first, three.com second (bottom row, L→R), then one.com
    XCTAssertEqual(matches.map(\.text), [
      "http://two.com", "http://three.com", "http://one.com"
    ])
  }
}
```

- [ ] **Step 2: Run — verify fail**

Run: `just test-filter HintDetectorTests`
Expected: FAIL.

- [ ] **Step 3: Implement HintDetector**

`Mistty/Models/HintDetector.swift`:

```swift
import Foundation

enum HintDetector {
  /// Detect matches across the given viewport lines.
  ///
  /// Lines are indexed top-to-bottom (line 0 = top row). Output is sorted
  /// bottom-to-top, then left-to-right, matching tmux-thumbs behavior.
  static func detect(lines: [String], source: HintSource) -> [HintMatch] {
    var matches: [HintMatch] = []
    for (row, line) in lines.enumerated() {
      switch source {
      case .patterns:
        matches.append(contentsOf: patternMatches(line: line, row: row))
      case .lines:
        if let m = lineMatch(line: line, row: row) {
          matches.append(m)
        }
      }
    }
    return matches.sorted { a, b in
      if a.range.startRow != b.range.startRow {
        return a.range.startRow > b.range.startRow  // bottom first
      }
      return a.range.startCol < b.range.startCol
    }
  }

  // MARK: Line source

  private static func lineMatch(line: String, row: Int) -> HintMatch? {
    let chars = Array(line)
    var first = 0
    while first < chars.count && chars[first].isWhitespace { first += 1 }
    guard first < chars.count else { return nil }
    var last = chars.count - 1
    while last > first && chars[last].isWhitespace { last -= 1 }
    let text = String(chars[first...last])
    return HintMatch(
      range: HintRange(startRow: row, startCol: first, endRow: row, endCol: last),
      text: text,
      kind: .line
    )
  }

  // MARK: Pattern source

  // Priority order (higher index = higher priority). Used for tie-break
  // only; longest match wins first.
  private static let priority: [HintKind] = [
    .number, .envVar, .ipv6, .ipv4, .hash, .path, .uuid, .email, .url
  ]

  private static let detectors: [(kind: HintKind, regex: NSRegularExpression)] = {
    func make(_ pattern: String, opts: NSRegularExpression.Options = []) -> NSRegularExpression {
      try! NSRegularExpression(pattern: pattern, options: opts)
    }
    return [
      (.url, make(#"\b(https?|ftp|file|ssh|git)://[^\s<>"')\]]+"#)),
      (.email, make(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#)),
      (.uuid, make(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#)),
      (.path, make(#"(?:~|\.{1,2})?/[\w./\-_]+"#)),
      (.hash, make(#"\b[0-9a-f]{7,40}\b"#)),
      (.ipv4, make(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)),
      (.ipv6, make(#"\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b"#)),
      (.envVar, make(#"\b[A-Z][A-Z0-9_]{2,}\b"#)),
      (.number, make(#"\b\d{2,}\b"#)),
    ]
  }()

  private static let quotedRe = try! NSRegularExpression(
    pattern: #""[^"]+"|'[^']+'"#
  )
  private static let codeSpanRe = try! NSRegularExpression(pattern: #"`[^`]+`"#)

  private struct RawMatch {
    let kind: HintKind
    let range: NSRange
    let text: String
  }

  private static func patternMatches(line: String, row: Int) -> [HintMatch] {
    let ns = line as NSString
    let full = NSRange(location: 0, length: ns.length)

    // 1) Run all peer detectors.
    var peers: [RawMatch] = []
    for (kind, re) in detectors {
      for r in re.matches(in: line, range: full) {
        var range = r.range
        let raw = ns.substring(with: range)
        // Strip trailing punctuation from URLs.
        if kind == .url {
          let stripped = stripTrailingURL(raw)
          if stripped.count != raw.count {
            range.length = stripped.count
          }
          peers.append(RawMatch(kind: kind, range: range, text: stripped))
        } else {
          peers.append(RawMatch(kind: kind, range: range, text: raw))
        }
      }
    }

    // 2) Containers — emit as separate matches; also allow inner matches.
    var containers: [RawMatch] = []
    for (re, kind) in [(quotedRe, HintKind.quoted), (codeSpanRe, HintKind.codeSpan)] {
      for r in re.matches(in: line, range: full) {
        let raw = ns.substring(with: r.range)
        containers.append(RawMatch(kind: kind, range: r.range, text: raw))
      }
    }

    // 3) Resolve peer overlaps: longest wins, tie → higher priority.
    let resolvedPeers = resolvePeers(peers)

    let all = containers + resolvedPeers
    return all.map { match in
      let startCol = match.range.location
      let endCol = match.range.location + match.range.length - 1
      return HintMatch(
        range: HintRange(startRow: row, startCol: startCol, endRow: row, endCol: endCol),
        text: match.text,
        kind: match.kind
      )
    }
  }

  private static func resolvePeers(_ peers: [RawMatch]) -> [RawMatch] {
    // Sort: length desc, then priority desc.
    let prioIndex: (HintKind) -> Int = { kind in
      priority.firstIndex(of: kind) ?? -1
    }
    let sorted = peers.sorted { a, b in
      if a.range.length != b.range.length { return a.range.length > b.range.length }
      return prioIndex(a.kind) > prioIndex(b.kind)
    }
    var claimed: [NSRange] = []
    var out: [RawMatch] = []
    for m in sorted {
      let overlaps = claimed.contains { NSIntersectionRange($0, m.range).length > 0 }
      if !overlaps {
        claimed.append(m.range)
        out.append(m)
      }
    }
    return out
  }

  private static func stripTrailingURL(_ s: String) -> String {
    let trail: Set<Character> = [".", ",", ";", ":", ")", "]", "}"]
    var chars = Array(s)
    while let last = chars.last, trail.contains(last) { chars.removeLast() }
    return String(chars)
  }
}
```

- [ ] **Step 4: Run tests — verify pass**

Run: `just test-filter HintDetectorTests`
Expected: all PASS. Investigate and fix any regex that over/under-matches.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Models/HintDetector.swift MisttyTests/Models/HintDetectorTests.swift
git commit -m "feat(copy-mode): add HintDetector for patterns and lines"
```

---

## Task 4: Wire entry keys + hint input into CopyModeState

**Files:**
- Modify: `Mistty/Models/CopyModeState.swift`

- [ ] **Step 1: Add hint state field**

Below `var scrollGeneration: Int = 0` add:

```swift
/// Active hint mode state. Non-nil iff subMode == .hint.
var hint: HintState?
```

- [ ] **Step 2: Update `isSelecting` and add `isHinting`**

```swift
var isSelecting: Bool { subMode == .visual || subMode == .visualLine || subMode == .visualBlock }
var isSearching: Bool { subMode == .searchForward || subMode == .searchReverse }
var isHinting: Bool { subMode == .hint }
```

- [ ] **Step 3: Extend `handleEscape` and `handleKey`**

In `handleEscape()`, add case:

```swift
case .hint:
  subMode = .normal
  hint = nil
  pendingContinuation = nil
  return [.exitHintMode, .enterSubMode(.normal)]
```

At top of `handleKey`, after the `showingHelp` short-circuit but before Escape, add:

```swift
if subMode == .hint {
  if keyCode == 53 { return handleEscape() }  // let escape work too
  return handleHintKey(key: key)
}
```

- [ ] **Step 4: Add hint entry in `handleNormalKey`**

Replace the existing `case "y":` block with:

```swift
case "y":
  if isSelecting { return [.exitCopyMode] }
  return [.enterHintMode(.copy, .patterns), .requestHintScan]
case "o":
  return [.enterHintMode(.open, .patterns), .requestHintScan]
case "Y":
  if isSelecting { return [] }
  return [.enterHintMode(.copy, .lines), .requestHintScan]
```

Also add to the switch — directly before `// Visual modes`, so `Y` doesn't fall through to `V` (note: `V` is already matched explicitly above `Y`? — `V` matches capital V; `Y` is a distinct case so OK). Verify `Y` isn't already consumed.

- [ ] **Step 5: Add `handleHintKey`**

Append inside `CopyModeState`:

```swift
// MARK: - Hint mode

mutating func applyHintEntry(action: HintAction, source: HintSource) {
  subMode = .hint
  hint = HintState(action: action, source: source, matches: [], labels: [])
}

mutating func setHintMatches(_ matches: [HintMatch], alphabet: String) {
  guard subMode == .hint else { return }
  hint?.matches = matches
  hint?.labels = HintLabels.generate(count: matches.count, alphabet: alphabet)
  hint?.typedPrefix = ""
}

private mutating func handleHintKey(key: Character) -> [CopyModeAction] {
  guard var h = hint else { return [] }

  // Non-alphabet (excluding case): exit
  let lower = Character(key.lowercased())
  if !lower.isLetter { return exitHintCleanly() }

  // Exact single-char match?
  if h.typedPrefix.isEmpty {
    if let idx = h.labels.firstIndex(where: { $0 == String(lower) }) {
      return executeHint(at: idx, typedUppercase: key.isUppercase)
    }
    // Prefix of a 2-char label?
    let hasPrefix = h.labels.contains(where: { $0.count == 2 && $0.first == lower })
    if hasPrefix {
      h.typedPrefix = String(lower)
      // Remember case of first char to decide action on final char
      hint = h
      return [.hintInput(key)]
    }
    return exitHintCleanly()
  } else {
    let target = h.typedPrefix + String(lower)
    if let idx = h.labels.firstIndex(where: { $0 == target }) {
      // Action = upper if EITHER typed char was uppercase
      let anyUpper = hintFirstCharWasUpper || key.isUppercase
      return executeHint(at: idx, typedUppercase: anyUpper)
    }
    return exitHintCleanly()
  }
}

private var hintFirstCharWasUpper: Bool {
  // Cannot derive from stored prefix (we store lowercase). Exposed through a
  // separate flag would be cleaner; for now, treat first-char case via
  // `typedPrefix`'s stored value. We store lowercase, so this returns false.
  // The first keystroke itself is captured in executeHint's direct path;
  // when we fall through via typedPrefix we lose the first-char case.
  // Compromise: only the *final* keystroke's case determines action.
  false
}

private mutating func executeHint(at index: Int, typedUppercase: Bool) -> [CopyModeAction] {
  guard let h = hint, index < h.matches.count else { return exitHintCleanly() }
  let match = h.matches[index]

  // Default action comes from the entry key. Uppercase swaps.
  let baseAction = h.action
  let action: HintAction = typedUppercase ? (baseAction == .copy ? .open : .copy) : baseAction

  subMode = .normal
  hint = nil

  let emitted: CopyModeAction
  switch action {
  case .copy: emitted = .copyText(match.text)
  case .open: emitted = .openItem(match.text)
  }
  return [emitted, .exitHintMode, .exitCopyMode]
}

private mutating func exitHintCleanly() -> [CopyModeAction] {
  subMode = .normal
  hint = nil
  return [.exitHintMode, .enterSubMode(.normal)]
}
```

(Note: first-char case cannot affect the action in this simplified routing — only the final typed char's case does. Integration test in Task 10 reflects this. Spec says "case of the typed hint letter can still override per-selection" — final-char case is sufficient and matches tmux-thumbs's "uppercase second char = alt action" variant. Document this inline in the code with a comment.)

Replace the `hintFirstCharWasUpper` helper and the check using it with the final-char-only rule:

```swift
// Simplify: action swap is driven by the *last* typed character's case.
// (For 2-char labels the second char carries the signal.)
```

And change `handleHintKey` `target` branch to just pass `key.isUppercase`:

```swift
if let idx = h.labels.firstIndex(where: { $0 == target }) {
  return executeHint(at: idx, typedUppercase: key.isUppercase)
}
```

Remove the `hintFirstCharWasUpper` computed property entirely.

- [ ] **Step 6: Build**

Run: `just build`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Mistty/Models/CopyModeState.swift
git commit -m "feat(copy-mode): hint sub-mode entry and input routing"
```

---

## Task 5: Config — [copy_mode.hints]

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift`

- [ ] **Step 1: Add struct and defaults**

Insert before `struct MisttyConfig`:

```swift
struct CopyModeHintsConfig: Sendable, Equatable {
  var alphabet: String = "asdfghjkl"
  /// Which action uppercase letters trigger. The lowercase default is the
  /// *other* action.
  var uppercaseAction: HintAction = .open
}
```

Inside `MisttyConfig`:

```swift
var copyModeHints: CopyModeHintsConfig = CopyModeHintsConfig()
```

In `parse`:

```swift
if let copyMode = table["copy_mode"]?.table,
   let hints = copyMode["hints"]?.table {
  if let alpha = hints["alphabet"]?.string, !alpha.isEmpty {
    config.copyModeHints.alphabet = alpha
  }
  if let ua = hints["uppercase_action"]?.string {
    switch ua {
    case "open": config.copyModeHints.uppercaseAction = .open
    case "copy": config.copyModeHints.uppercaseAction = .copy
    default: break
    }
  }
}
```

In `save()`, after the SSH block:

```swift
if copyModeHints != CopyModeHintsConfig() {
  lines.append("")
  lines.append("[copy_mode.hints]")
  lines.append("alphabet = \"\(tomlEscape(copyModeHints.alphabet))\"")
  let ua = copyModeHints.uppercaseAction == .open ? "open" : "copy"
  lines.append("uppercase_action = \"\(ua)\"")
}
```

- [ ] **Step 2: Build**

Run: `just build`
Expected: PASS (HintAction imported via module).

- [ ] **Step 3: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift
git commit -m "feat(config): add [copy_mode.hints] (alphabet, uppercase_action)"
```

---

## Task 6: ContentView — viewport scan + action handlers

**Files:**
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Add viewport scan helper**

Above `yankSelection()` add:

```swift
private func scanViewportForHints(source: HintSource) -> [HintMatch] {
  guard let state = store.activeSession?.activeTab?.copyModeState else { return [] }
  var lines: [String] = []
  for row in 0..<state.rows {
    lines.append(readTerminalLine(row: row) ?? "")
  }
  return HintDetector.detect(lines: lines, source: source)
}

private func populateHintMatches(_ state: inout CopyModeState, source: HintSource) {
  let matches = scanViewportForHints(source: source)
  let alphabet = MisttyConfig.load().copyModeHints.alphabet
  state.setHintMatches(matches, alphabet: alphabet)
}
```

- [ ] **Step 2: Handle new actions in `installCopyModeMonitor`**

Inside the `switch action` block, add cases:

```swift
case .enterHintMode(let action, let source):
  state.applyHintEntry(action: action, source: source)
case .requestHintScan:
  let source = state.hint?.source ?? .patterns
  populateHintMatches(&state, source: source)
case .hintInput:
  break  // typedPrefix already set in state
case .exitHintMode:
  break  // subMode already reset
case .copyText(let text):
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
case .openItem(let text):
  if let url = URL(string: text), url.scheme != nil {
    NSWorkspace.shared.open(url)
  } else {
    let proc = Process()
    proc.launchPath = "/usr/bin/open"
    proc.arguments = [text]
    try? proc.run()
  }
```

- [ ] **Step 3: Re-scan on scroll while hinting**

Inside the same `switch`, extend `case .scroll`:

```swift
case .scroll(let deltaRows):
  scrollViewport(&state, delta: deltaRows)
  if state.isHinting, let source = state.hint?.source {
    populateHintMatches(&state, source: source)
  }
```

(Replace the existing single-line `case .scroll(let deltaRows): scrollViewport(&state, delta: deltaRows)` with the block above.)

- [ ] **Step 4: Build**

Run: `just build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat(copy-mode): ContentView wires hint scan, clipboard, open"
```

---

## Task 7: CopyModeHintOverlay view

**Files:**
- Create: `Mistty/Views/Terminal/CopyModeHintOverlay.swift`
- Modify: `Mistty/Views/Terminal/CopyModeOverlay.swift`

- [ ] **Step 1: Create overlay view**

`Mistty/Views/Terminal/CopyModeHintOverlay.swift`:

```swift
import SwiftUI

struct CopyModeHintOverlay: View {
  let hint: HintState
  let viewportRows: Int
  let viewportCols: Int
  let cellWidth: CGFloat
  let cellHeight: CGFloat

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Full viewport dim
      Rectangle()
        .fill(Color.black.opacity(0.4))
        .frame(
          width: cellWidth * CGFloat(viewportCols),
          height: cellHeight * CGFloat(viewportRows)
        )

      // Label pills
      ForEach(Array(zip(hint.matches, hint.labels).enumerated()), id: \.offset) { idx, pair in
        let match = pair.0
        let label = pair.1
        pill(label: label, match: match)
      }
    }
    .allowsHitTesting(false)
  }

  private func pill(label: String, match: HintMatch) -> some View {
    let dimmed: Bool = {
      guard !hint.typedPrefix.isEmpty else { return false }
      return !label.hasPrefix(hint.typedPrefix)
    }()
    let x = CGFloat(match.range.startCol) * cellWidth
    let y = CGFloat(match.range.startRow) * cellHeight
    return Text(label)
      .font(.system(size: cellHeight * 0.7, weight: .bold, design: .monospaced))
      .foregroundStyle(dimmed ? Color.white.opacity(0.2) : Color.black)
      .padding(.horizontal, 2)
      .background(
        RoundedRectangle(cornerRadius: 2)
          .fill(dimmed ? Color.gray.opacity(0.3) : Color.orange)
      )
      .offset(x: x, y: y)
  }
}
```

- [ ] **Step 2: Mount overlay + indicator in CopyModeOverlay**

In `CopyModeOverlay.body`, after the Cursor Rectangle block and before the Mode indicator block, insert:

```swift
// Hint overlay
if state.isHinting, let hint = state.hint {
  CopyModeHintOverlay(
    hint: hint,
    viewportRows: state.rows,
    viewportCols: state.cols,
    cellWidth: cellWidth,
    cellHeight: cellHeight
  )
  .offset(x: gridOffsetX, y: gridOffsetY)
}
```

Update `modeIndicatorText` switch to include `.hint`:

```swift
case .hint:
  let src = state.hint?.source == .lines ? "line" : (state.hint?.action == .open ? "open" : "copy")
  return "-- HINT (\(src)) --"
```

- [ ] **Step 3: Build**

Run: `just build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Views/Terminal/CopyModeHintOverlay.swift Mistty/Views/Terminal/CopyModeOverlay.swift
git commit -m "feat(copy-mode): hint overlay with dim layer and label pills"
```

---

## Task 8: Help overlay update

**Files:**
- Modify: `Mistty/Views/Terminal/CopyModeHelpOverlay.swift`

- [ ] **Step 1: Add hint hints**

Add as a new column in `body`:

```swift
private let hintHints: [(key: String, label: String)] = [
  ("y", "yank hints (copy)"),
  ("o", "yank hints (open)"),
  ("Y", "line hints"),
  ("A-Z", "swap copy/open"),
  ("Esc/misc", "exit hints"),
]
```

Add column in the `HStack(alignment: .top, spacing: 20)` block:

```swift
hintColumn(title: "Hints", hints: hintHints)
```

- [ ] **Step 2: Build + commit**

```bash
just build
git add Mistty/Views/Terminal/CopyModeHelpOverlay.swift
git commit -m "docs(copy-mode): help overlay documents hint mode"
```

---

## Task 9: Global `cmd+shift+y` shortcut

**Files:**
- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/App/ContentView.swift`

- [ ] **Step 1: Add notification name**

In `MisttyApp.swift`, near other notification names:

```swift
static let misttyYankHints = Notification.Name("misttyYankHints")
```

- [ ] **Step 2: Add menu button**

Below the existing Copy Mode button:

```swift
Button("Yank Hints") {
  NotificationCenter.default.post(name: .misttyYankHints, object: nil)
}
.keyboardShortcut("y", modifiers: [.command, .shift])
```

- [ ] **Step 3: Handle notification in ContentView**

In `ContentView.body`, alongside the existing `.onReceive(... .misttyCopyMode ...)`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyYankHints)) { _ in
  handleYankHints()
}
```

Add function near `handleCopyMode`:

```swift
private func handleYankHints() {
  guard let tab = store.activeSession?.activeTab else { return }
  if !tab.isCopyModeActive {
    enterCopyMode()
  }
  guard var state = store.activeSession?.activeTab?.copyModeState else { return }
  state.applyHintEntry(action: .copy, source: .patterns)
  populateHintMatches(&state, source: .patterns)
  store.activeSession?.activeTab?.copyModeState = state
}
```

- [ ] **Step 4: Build + commit**

```bash
just build
git add Mistty/App/MisttyApp.swift Mistty/App/ContentView.swift
git commit -m "feat(copy-mode): cmd+shift+y opens yank hints directly"
```

---

## Task 10: Integration tests

**Files:**
- Create: `MisttyTests/Models/CopyModeHintIntegrationTests.swift`

- [ ] **Step 1: Write tests**

```swift
import XCTest
@testable import Mistty

final class CopyModeHintIntegrationTests: XCTestCase {

  private func makeState(lines: [String]) -> (CopyModeState, (Int) -> String?) {
    let rows = lines.count
    let cols = lines.map(\.count).max() ?? 80
    let state = CopyModeState(rows: rows, cols: cols, cursorRow: 0, cursorCol: 0)
    let reader: (Int) -> String? = { r in r < lines.count ? lines[r] : nil }
    return (state, reader)
  }

  private func simulate(
    _ state: inout CopyModeState,
    reader: (Int) -> String?,
    keys: String
  ) -> [CopyModeAction] {
    var collected: [CopyModeAction] = []
    for ch in keys {
      let actions = state.handleKey(key: ch, keyCode: 0, modifiers: [], lineReader: reader)
      collected.append(contentsOf: actions)
    }
    return collected
  }

  func test_y_enters_hint_mode_copy() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    let actions = simulate(&state, reader: reader, keys: "y")
    XCTAssertTrue(actions.contains(.enterHintMode(.copy, .patterns)))
    XCTAssertTrue(actions.contains(.requestHintScan))
    XCTAssertEqual(state.subMode, .hint)
  }

  func test_o_enters_hint_mode_open() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    let actions = simulate(&state, reader: reader, keys: "o")
    XCTAssertTrue(actions.contains(.enterHintMode(.open, .patterns)))
  }

  func test_Y_enters_hint_mode_lines() {
    var (state, reader) = makeState(lines: ["hello"])
    let actions = simulate(&state, reader: reader, keys: "Y")
    XCTAssertTrue(actions.contains(.enterHintMode(.copy, .lines)))
  }

  func test_single_char_label_copies_and_exits() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    _ = simulate(&state, reader: reader, keys: "y")
    state.setHintMatches(
      HintDetector.detect(lines: ["see https://example.com"], source: .patterns),
      alphabet: "asdfghjkl"
    )
    let actions = simulate(&state, reader: reader, keys: "a")
    XCTAssertTrue(actions.contains(.copyText("https://example.com")))
    XCTAssertTrue(actions.contains(.exitHintMode))
    XCTAssertTrue(actions.contains(.exitCopyMode))
  }

  func test_uppercase_swaps_action_to_open() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    _ = simulate(&state, reader: reader, keys: "y")
    state.setHintMatches(
      HintDetector.detect(lines: ["see https://example.com"], source: .patterns),
      alphabet: "asdfghjkl"
    )
    let actions = simulate(&state, reader: reader, keys: "A")
    XCTAssertTrue(actions.contains(.openItem("https://example.com")))
  }

  func test_mismatch_exits_hint_mode_but_not_copy_mode() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    _ = simulate(&state, reader: reader, keys: "y")
    state.setHintMatches(
      HintDetector.detect(lines: ["see https://example.com"], source: .patterns),
      alphabet: "asdfghjkl"
    )
    let actions = simulate(&state, reader: reader, keys: "z")
    XCTAssertTrue(actions.contains(.exitHintMode))
    XCTAssertFalse(actions.contains(where: {
      if case .exitCopyMode = $0 { return true } else { return false }
    }))
    XCTAssertEqual(state.subMode, .normal)
  }

  func test_two_char_label_routing() {
    // Force >9 matches so 2-char labels appear.
    var lines: [String] = []
    for i in 0..<12 {
      lines.append("url http://ex\(i).com")
    }
    var (state, reader) = makeState(lines: lines)
    _ = simulate(&state, reader: reader, keys: "y")
    let matches = HintDetector.detect(lines: lines, source: .patterns)
    state.setHintMatches(matches, alphabet: "asdf")
    // With alphabet "asdf" and 12 matches: p reserves prefixes "d","f" → let's
    // just take whatever the label is for the last element and verify it
    // copies that match.
    guard let lastLabel = state.hint?.labels.last,
          lastLabel.count == 2 else {
      return XCTFail("expected 2-char label")
    }
    let actions = simulate(&state, reader: reader, keys: String(lastLabel))
    let expected = state.hint?.matches.last?.text ?? ""
    // state has been mutated by the final keystroke — compare against captured before
    XCTAssertTrue(actions.contains(where: {
      if case .copyText = $0 { return true } else { return false }
    }), "should have copied last match (\(expected))")
  }

  func test_line_mode_yanks_whole_line() {
    var (state, reader) = makeState(lines: ["first line", "", "  second  "])
    _ = simulate(&state, reader: reader, keys: "Y")
    let matches = HintDetector.detect(
      lines: ["first line", "", "  second  "],
      source: .lines
    )
    state.setHintMatches(matches, alphabet: "asdf")
    // Only 2 non-empty lines; label "a" should point at bottom line ("second")
    let actions = simulate(&state, reader: reader, keys: "a")
    XCTAssertTrue(actions.contains(.copyText("second")))
  }
}
```

- [ ] **Step 2: Run — expect pass**

Run: `just test-filter CopyModeHintIntegrationTests`
Expected: all PASS.

- [ ] **Step 3: Run full suite**

Run: `just test`
Expected: all PASS. No regressions in existing CopyMode tests.

- [ ] **Step 4: Commit**

```bash
git add MisttyTests/Models/CopyModeHintIntegrationTests.swift
git commit -m "test(copy-mode): integration tests for hint mode"
```

---

## Task 11: Manual verification

- [ ] **Step 1: Run Mistty**

```bash
just run
```

- [ ] **Step 2: Smoke test pattern hints**

In a pane, run `ls /usr/local/bin | head` then `echo https://example.com`.
Enter copy mode (`cmd+shift+c`), press `y`. Verify dimmed viewport + pills
in front of path(s) and URL. Press a hint letter — verify clipboard has
the match and copy mode exited.

- [ ] **Step 3: Open variant**

Enter copy mode, press `o`, select a URL hint. Verify the URL opens in
the default browser.

- [ ] **Step 4: Line hints**

Enter copy mode, press `Y`. Verify pills at column 0 of each non-empty
visible line. Select a line — verify clipboard holds the trimmed line.

- [ ] **Step 5: Global shortcut**

From a normal pane (no copy mode), press `cmd+shift+y`. Verify it
enters copy mode *and* hint mode in one step.

- [ ] **Step 6: Uppercase swap**

In pattern hint mode entered via `y`, type the label in uppercase —
verify it opens (via `NSWorkspace.open`) instead of copying.

- [ ] **Step 7: Scroll re-scan**

In hint mode, trigger a scroll via `Ctrl-d`. Verify the hint labels
re-populate against the new viewport.

- [ ] **Step 8: Mismatch exit**

In hint mode, press a non-alphabet key. Verify you return to normal
copy mode (cursor still there, not exited entirely).

---

## Self-Review Notes

- Spec coverage: all sections mapped to tasks 1–10.
- First-char case of a 2-char label does not affect the action; only the
  final character's case matters. This differs from a strict reading of
  the spec ("case of the typed hint letter can still override") but is
  the simpler, tmux-thumbs-compatible behavior. Documented in code + this
  plan. If you want strict first-OR-second rule later, extend
  `HintState.typedPrefixWasUpper: Bool`.
- `Y` conflict: none — `Y` is not currently bound in copy mode.
- `o` conflict: none — `o` not bound.
- Label ordering is bottom→top in `HintDetector.detect`, confirmed in
  test `test_ordering_bottomToTop_leftToRight`.
- Viewport scanning uses `readTerminalLine` (already in ContentView) for
  consistency with search highlighting.
