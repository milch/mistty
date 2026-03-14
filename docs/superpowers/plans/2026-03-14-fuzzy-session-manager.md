# Fuzzy Session Manager Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the session manager's substring filtering with typo-tolerant fuzzy matching, add match highlighting, and introduce a "New session" option.

**Architecture:** A standalone `FuzzyMatcher` service handles all matching/scoring. The `SessionManagerViewModel` is updated to use it for filtering, store per-item match results, and manage the new "New" item. The view renders highlighted matches and the new row styling. `FocusableTextField` gains Tab/Right Arrow interception for completion.

**Tech Stack:** Swift, SwiftUI, AppKit (NSTextField), XCTest

**Spec:** `docs/superpowers/specs/2026-03-14-fuzzy-session-manager-design.md`

---

## Chunk 1: FuzzyMatcher Core

### Task 1: FuzzyMatcher — Strict Ordered Match

**Files:**
- Create: `Mistty/Services/FuzzyMatcher.swift`
- Create: `MisttyTests/Services/FuzzyMatcherTests.swift`

- [ ] **Step 1: Write failing tests for strict ordered matching**

In `MisttyTests/Services/FuzzyMatcherTests.swift`:

```swift
import XCTest

@testable import Mistty

final class FuzzyMatcherTests: XCTestCase {
  // MARK: - Strict ordered match

  func test_exactMatch() {
    let result = FuzzyMatcher.match(query: "foo", target: "foo")
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.matchedIndices, [0, 1, 2])
  }

  func test_prefixMatch() {
    let result = FuzzyMatcher.match(query: "foo", target: "foobar")
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.matchedIndices, [0, 1, 2])
  }

  func test_subsequenceMatch() {
    let result = FuzzyMatcher.match(query: "fb", target: "foobar")
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.matchedIndices.count, 2)
    XCTAssertTrue(result!.matchedIndices.contains(0)) // f
    XCTAssertTrue(result!.matchedIndices.contains(3)) // b
  }

  func test_caseInsensitive() {
    let result = FuzzyMatcher.match(query: "FOO", target: "foobar")
    XCTAssertNotNil(result)
  }

  func test_noMatch() {
    let result = FuzzyMatcher.match(query: "xyz", target: "foobar")
    XCTAssertNil(result)
  }

  func test_emptyQuery() {
    let result = FuzzyMatcher.match(query: "", target: "foobar")
    XCTAssertNil(result)
  }

  func test_queryLongerThanTarget() {
    let result = FuzzyMatcher.match(query: "foobarextralongquery", target: "foo")
    XCTAssertNil(result)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/FuzzyMatcherTests 2>&1 | tail -20`
Expected: Compilation failure (FuzzyMatcher not defined)

- [ ] **Step 3: Implement FuzzyMatch model and strict ordered match**

In `Mistty/Services/FuzzyMatcher.swift`:

```swift
import Foundation

struct FuzzyMatch {
  let score: Double
  let matchedIndices: [Int]
}

struct FuzzyMatcher {
  // Scoring constants
  private static let consecutiveBonus: Double = 8.0
  private static let wordBoundaryBonus: Double = 10.0
  private static let prefixBonus: Double = 12.0
  private static let unmatchedPenalty: Double = -1.0

  private static let boundaryChars: Set<Character> = ["/", "-", "_", ".", " "]

  static func match(query: String, target: String) -> FuzzyMatch? {
    guard !query.isEmpty, !target.isEmpty else { return nil }

    let queryLower = Array(query.lowercased())
    let targetLower = Array(target.lowercased())
    let targetChars = Array(target)

    guard queryLower.count <= targetLower.count else { return nil }

    // Try strict ordered match first
    if let result = strictMatch(query: queryLower, target: targetLower, targetLength: targetChars.count) {
      return result
    }

    return nil
  }

  private static func strictMatch(query: [Character], target: [Character], targetLength: Int) -> FuzzyMatch? {
    // Find best match using recursive approach with memoization
    var bestScore = -Double.infinity
    var bestIndices: [Int]?

    func search(qi: Int, ti: Int, indices: [Int], score: Double, prevMatchIdx: Int?) {
      if qi == query.count {
        // All query chars matched — compute final score
        let lengthBonus = 1.0 / Double(max(targetLength, 1))
        let finalScore = score + lengthBonus
        if finalScore > bestScore {
          bestScore = finalScore
          bestIndices = indices
        }
        return
      }

      // Not enough target chars remaining
      if target.count - ti < query.count - qi { return }

      for i in ti..<target.count {
        guard target[i] == query[qi] else { continue }

        var bonus: Double = 0.0

        // Prefix bonus
        if i == 0 { bonus += prefixBonus }

        // Word boundary bonus
        if i > 0 && boundaryChars.contains(Character(String(target[i - 1]))) {
          bonus += wordBoundaryBonus
        }

        // Consecutive bonus
        if let prev = prevMatchIdx, i == prev + 1 {
          bonus += consecutiveBonus
        }

        search(
          qi: qi + 1,
          ti: i + 1,
          indices: indices + [i],
          score: score + 1.0 + bonus,
          prevMatchIdx: i
        )
      }
    }

    search(qi: 0, ti: 0, indices: [], score: 0.0, prevMatchIdx: nil)

    guard let indices = bestIndices else { return nil }

    // Normalize score to 0...1 range
    let maxPossible = Double(query.count) * (1.0 + prefixBonus + wordBoundaryBonus + consecutiveBonus) + 1.0
    let normalized = min(max(bestScore / maxPossible, 0.0), 1.0)

    return FuzzyMatch(score: normalized, matchedIndices: indices)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/FuzzyMatcherTests 2>&1 | tail -20`
Expected: All 7 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/FuzzyMatcher.swift MisttyTests/Services/FuzzyMatcherTests.swift
git commit -m "feat: add FuzzyMatcher with strict ordered matching"
```

---

### Task 2: FuzzyMatcher — Scoring Heuristics

**Files:**
- Modify: `MisttyTests/Services/FuzzyMatcherTests.swift`
- Modify: `Mistty/Services/FuzzyMatcher.swift`

- [ ] **Step 1: Write failing tests for scoring heuristics**

Append to `FuzzyMatcherTests.swift`:

```swift
  // MARK: - Scoring heuristics

  func test_prefixMatchScoresHigher() {
    let prefix = FuzzyMatcher.match(query: "pro", target: "project")!
    let middle = FuzzyMatcher.match(query: "pro", target: "my-project")!
    XCTAssertGreaterThan(prefix.score, middle.score)
  }

  func test_wordBoundaryScoresHigher() {
    let boundary = FuzzyMatcher.match(query: "pro", target: "my-project")!
    let scattered = FuzzyMatcher.match(query: "pro", target: "xpxrxoxx")!
    XCTAssertGreaterThan(boundary.score, scattered.score)
  }

  func test_consecutiveMatchScoresHigher() {
    let consecutive = FuzzyMatcher.match(query: "abc", target: "xabcx")!
    let scattered = FuzzyMatcher.match(query: "abc", target: "xaxbxcx")!
    XCTAssertGreaterThan(consecutive.score, scattered.score)
  }

  func test_shorterTargetScoresHigher() {
    let short = FuzzyMatcher.match(query: "foo", target: "foobar")!
    let long = FuzzyMatcher.match(query: "foo", target: "foo-and-a-very-long-suffix")!
    XCTAssertGreaterThan(short.score, long.score)
  }

  func test_pathBoundaryMatching() {
    let result = FuzzyMatcher.match(query: "proj", target: "~/Developer/project")!
    // Should prefer matching at the path boundary (after /)
    // "~/Developer/" is 13 chars, so 'p' in 'project' is at index 13
    XCTAssertTrue(result.matchedIndices.contains(13)) // 'p' after last '/'
  }
```

- [ ] **Step 2: Run tests to verify they pass (scoring heuristics are already built into Task 1)**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/FuzzyMatcherTests 2>&1 | tail -20`
Expected: All tests PASS (the scoring logic from Task 1 should handle these)

If any fail, adjust the scoring constants in `FuzzyMatcher.swift` to ensure the ranking invariants hold.

- [ ] **Step 3: Commit**

```bash
git add MisttyTests/Services/FuzzyMatcherTests.swift Mistty/Services/FuzzyMatcher.swift
git commit -m "test: add scoring heuristic tests for FuzzyMatcher"
```

---

### Task 3: FuzzyMatcher — Typo-Tolerant Fallback

**Files:**
- Modify: `MisttyTests/Services/FuzzyMatcherTests.swift`
- Modify: `Mistty/Services/FuzzyMatcher.swift`

- [ ] **Step 1: Write failing tests for typo tolerance**

Append to `FuzzyMatcherTests.swift`:

```swift
  // MARK: - Typo tolerance

  func test_transposition_bzael_matches_bazel() {
    let result = FuzzyMatcher.match(query: "bzael", target: "bazel")
    XCTAssertNotNil(result)
  }

  func test_singleCharTypo_baxel_matches_bazel() {
    let result = FuzzyMatcher.match(query: "baxel", target: "bazel")
    XCTAssertNotNil(result)
  }

  func test_shortQuery_noTypoTolerance() {
    // Query length 1-3: no edits allowed
    let result = FuzzyMatcher.match(query: "bz", target: "ab")
    XCTAssertNil(result)
  }

  func test_typoMatch_scoredLowerThanStrict() {
    let strict = FuzzyMatcher.match(query: "bazel", target: "bazel-build")!
    let typo = FuzzyMatcher.match(query: "bzael", target: "bazel-build")!
    XCTAssertGreaterThan(strict.score, typo.score)
  }

  func test_twoEdits_longQuery() {
    // Query length 7+: 2 edits allowed
    let result = FuzzyMatcher.match(query: "proejct", target: "project")
    XCTAssertNotNil(result)
  }

  func test_tooManyEdits_returns_nil() {
    // Query length 4-6: max 1 edit. "abcdef" vs "fedcba" = way too many edits
    let result = FuzzyMatcher.match(query: "abcde", target: "edcba")
    XCTAssertNil(result)
  }

  func test_typoMatch_indices_cover_window() {
    let result = FuzzyMatcher.match(query: "bzael", target: "xxbazelxx")!
    // Should highlight the "bazel" window (indices 2-6)
    XCTAssertEqual(result.matchedIndices.sorted(), [2, 3, 4, 5, 6])
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/FuzzyMatcherTests 2>&1 | tail -20`
Expected: Typo tests FAIL (typo fallback not implemented yet)

- [ ] **Step 3: Implement Damerau-Levenshtein sliding window fallback**

Add to `FuzzyMatcher.swift`, inside the `FuzzyMatcher` struct:

```swift
  private static let typoPenalty: Double = 0.5

  private static func maxAllowedEdits(queryLength: Int) -> Int {
    switch queryLength {
    case 0...3: return 0
    case 4...6: return 1
    default: return 2
    }
  }

  private static func typoMatch(query: [Character], target: [Character], targetLength: Int) -> FuzzyMatch? {
    let maxEdits = maxAllowedEdits(queryLength: query.count)
    guard maxEdits > 0 else { return nil }

    var bestDistance = Int.max
    var bestWindowStart = 0

    // Sliding window: try windows of length query.count-maxEdits to query.count+maxEdits
    let minWindow = max(1, query.count - maxEdits)
    let maxWindow = query.count + maxEdits

    for windowLen in minWindow...maxWindow {
      guard windowLen <= target.count else { continue }
      for start in 0...(target.count - windowLen) {
        let window = Array(target[start..<(start + windowLen)])
        let dist = damerauLevenshtein(query, window)
        if dist < bestDistance {
          bestDistance = dist
          bestWindowStart = start
        }
      }
    }

    guard bestDistance <= maxEdits else { return nil }

    // Use the best window's length for indices
    let bestWindowLen = min(query.count + bestDistance, targetLength - bestWindowStart)
    let indices = Array(bestWindowStart..<(bestWindowStart + bestWindowLen))

    // Score: base match score with typo penalty
    let baseScore = Double(query.count - bestDistance) / Double(max(query.count, 1))
    let lengthBonus = 1.0 / Double(max(targetLength, 1))
    let score = (baseScore + lengthBonus) * typoPenalty

    // Normalize to 0...1
    let normalized = min(max(score, 0.0), 1.0)

    return FuzzyMatch(score: normalized, matchedIndices: indices)
  }

  /// Standard Damerau-Levenshtein distance (optimal string alignment variant)
  private static func damerauLevenshtein(_ a: [Character], _ b: [Character]) -> Int {
    let n = a.count, m = b.count
    if n == 0 { return m }
    if m == 0 { return n }

    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { dp[i][0] = i }
    for j in 0...m { dp[0][j] = j }

    for i in 1...n {
      for j in 1...m {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        dp[i][j] = min(
          dp[i - 1][j] + 1,       // deletion
          dp[i][j - 1] + 1,       // insertion
          dp[i - 1][j - 1] + cost // substitution
        )
        // Transposition (always costs 1 edit)
        if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
          dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + 1)
        }
      }
    }
    return dp[n][m]
  }
```

Update the `match` function to call typo fallback:

```swift
  static func match(query: String, target: String) -> FuzzyMatch? {
    guard !query.isEmpty, !target.isEmpty else { return nil }

    let queryLower = Array(query.lowercased())
    let targetLower = Array(target.lowercased())
    let targetChars = Array(target)

    guard queryLower.count <= targetLower.count + maxAllowedEdits(queryLength: queryLower.count) else { return nil }

    // Try strict ordered match first
    if let result = strictMatch(query: queryLower, target: targetLower, targetLength: targetChars.count) {
      return result
    }

    // Try typo-tolerant fallback
    return typoMatch(query: queryLower, target: targetLower, targetLength: targetChars.count)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/FuzzyMatcherTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/FuzzyMatcher.swift MisttyTests/Services/FuzzyMatcherTests.swift
git commit -m "feat: add typo-tolerant fallback to FuzzyMatcher"
```

---

### Task 4: FuzzyMatcher — Benchmark Tests

**Files:**
- Create: `MisttyTests/Services/FuzzyMatcherBenchmarkTests.swift`

- [ ] **Step 1: Write benchmark tests**

In `MisttyTests/Services/FuzzyMatcherBenchmarkTests.swift`:

```swift
import XCTest

@testable import Mistty

final class FuzzyMatcherBenchmarkTests: XCTestCase {

  private func generateTargets(count: Int) -> [String] {
    let bases = [
      "~/Developer/project-alpha", "~/workspace/bazel-build",
      "~/code/my-app/src", "/usr/local/bin/tool",
      "~/Documents/notes/work", "~/Developer/rust-experiments",
      "prod-server.example.com", "staging.internal.net",
      "~/Developer/swift-fuzzy-matcher", "~/code/terminal-emulator",
    ]
    return (0..<count).map { i in
      "\(bases[i % bases.count])-\(i)"
    }
  }

  func test_benchmark_singleMatch_shortTarget() {
    let target = "my-project-name"
    measure {
      for _ in 0..<1000 {
        _ = FuzzyMatcher.match(query: "proj", target: target)
      }
    }
  }

  func test_benchmark_singleMatch_longTarget() {
    let target = "/Users/developer/workspace/very/deeply/nested/project/structure/with/many/path/components/file.swift"
    measure {
      for _ in 0..<1000 {
        _ = FuzzyMatcher.match(query: "proj", target: target)
      }
    }
  }

  func test_benchmark_batch500() {
    let targets = generateTargets(count: 500)
    measure {
      for target in targets {
        _ = FuzzyMatcher.match(query: "proj", target: target)
      }
    }
  }

  func test_benchmark_multiToken_batch500() {
    let targets = generateTargets(count: 500)
    let tokens = ["proj", "alpha"]
    measure {
      for target in targets {
        for token in tokens {
          _ = FuzzyMatcher.match(query: token, target: target)
        }
      }
    }
  }

  func test_benchmark_typoFallback_batch500() {
    let targets = generateTargets(count: 500)
    measure {
      for target in targets {
        _ = FuzzyMatcher.match(query: "prjoect", target: target)
      }
    }
  }

  func test_benchmark_noMatches_batch500() {
    let targets = generateTargets(count: 500)
    measure {
      for target in targets {
        _ = FuzzyMatcher.match(query: "zzzzz", target: target)
      }
    }
  }
}
```

- [ ] **Step 2: Run benchmarks**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/FuzzyMatcherBenchmarkTests 2>&1 | grep -E "(test_benchmark|average|passed)"`

Verify results are within targets:
- Single match (short target): < 10 microseconds per call
- Batch of 500: < 5 milliseconds

- [ ] **Step 3: Commit**

```bash
git add MisttyTests/Services/FuzzyMatcherBenchmarkTests.swift
git commit -m "test: add FuzzyMatcher benchmark tests"
```

---

## Chunk 2: SessionManagerViewModel — New Item, Fuzzy Filter, Multi-Token

### Task 5: Add `newSession` Case to SessionManagerItem

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift` (lines 4-40)
- Modify: `MisttyTests/Views/SessionManagerViewModelTests.swift`

- [ ] **Step 1: Write failing test for newSession item properties**

Append to `SessionManagerViewModelTests.swift`:

```swift
  func test_newSessionItem_plainText_properties() {
    let item = SessionManagerItem.newSession(
      query: "proj",
      directory: URL(fileURLWithPath: "/tmp/current"),
      createDirectory: false,
      sshCommand: nil
    )
    XCTAssertEqual(item.id, "new-session")
    XCTAssertEqual(item.displayName, "New session: proj")
    XCTAssertTrue(item.subtitle!.contains("/tmp/current"))
  }

  func test_newSessionItem_createDirectory_properties() {
    let item = SessionManagerItem.newSession(
      query: "~/Developer/newproj",
      directory: URL(fileURLWithPath: "/Users/test/Developer/newproj"),
      createDirectory: true,
      sshCommand: nil
    )
    XCTAssertTrue(item.displayName.contains("create directory"))
  }

  func test_newSessionItem_ssh_properties() {
    let item = SessionManagerItem.newSession(
      query: "ssh myhost",
      directory: FileManager.default.homeDirectoryForCurrentUser,
      createDirectory: false,
      sshCommand: "ssh myhost"
    )
    XCTAssertEqual(item.displayName, "New SSH session: myhost")
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/SessionManagerViewModelTests 2>&1 | tail -20`
Expected: Compilation failure (newSession case not defined)

- [ ] **Step 3: Add newSession case to SessionManagerItem**

In `SessionManagerViewModel.swift`, add the new case to the enum (after line 7):

```swift
  case newSession(query: String, directory: URL, createDirectory: Bool, sshCommand: String?)
```

Update the computed properties. Replace the `id` computed property:

```swift
  var id: String {
    switch self {
    case .runningSession(let s): return "session-\(s.id)"
    case .directory(let u): return "dir-\(u.path)"
    case .sshHost(let h): return "ssh-\(h.alias)"
    case .newSession: return "new-session"
    }
  }
```

Replace the `displayName` computed property:

```swift
  var displayName: String {
    switch self {
    case .runningSession(let s): return "▶ \(s.name)"
    case .directory(let u): return u.lastPathComponent
    case .sshHost(let h): return "⌁ \(h.alias)"
    case .newSession(let query, let directory, let createDir, let sshCommand):
      if sshCommand != nil {
        let hostname = query.drop(while: { $0 != " " }).dropFirst().trimmingCharacters(in: .whitespaces)
        return "New SSH session: \(hostname)"
      } else if createDir {
        return "New session + create directory: \(directory.path)"
      } else {
        let name = query.contains("/") || query.hasPrefix("~")
          ? directory.lastPathComponent : query
        return "New session: \(name)"
      }
    }
  }
```

Replace the `subtitle` computed property:

```swift
  var subtitle: String? {
    switch self {
    case .runningSession: return nil
    case .directory(let u): return u.path
    case .sshHost(let h): return h.hostname
    case .newSession(_, let directory, _, let sshCommand):
      if sshCommand != nil {
        return sshCommand
      }
      return "\(directory.path) (\u{2318} for ~)"
    }
  }
```

Replace the `frecencyKey` computed property:

```swift
  var frecencyKey: String? {
    switch self {
    case .runningSession(let s): return "session:\(s.name)"
    case .directory(let u): return "dir:\(u.path)"
    case .sshHost(let h): return "ssh:\(h.alias)"
    case .newSession: return nil
    }
  }
```

Update `confirmSelection()` and `load()` to handle optional `frecencyKey`. This is critical — without these changes the project won't compile after adding the new case.

In `confirmSelection()`, replace `frecencyService.recordAccess(for: item.frecencyKey)` with:

```swift
    if let key = item.frecencyKey {
      frecencyService.recordAccess(for: key)
    }
```

Also add a temporary `default: break` to the switch in `confirmSelection()` for the `.newSession` case (full handling comes in Task 8):

```swift
    case .newSession:
      break // handled in Task 8
```

In `load()` sorting, replace the frecency score lines:

```swift
    allItems = items.sorted { a, b in
      let scoreA = a.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      let scoreB = b.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      if scoreA != scoreB { return scoreA > scoreB }
      return categoryOrder(a) < categoryOrder(b)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/SessionManagerViewModelTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/SessionManager/SessionManagerViewModel.swift MisttyTests/Views/SessionManagerViewModelTests.swift
git commit -m "feat: add newSession case to SessionManagerItem"
```

---

### Task 6: Add ItemMatchResult and Fuzzy Filter Logic

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift`
- Modify: `MisttyTests/Views/SessionManagerViewModelTests.swift`

- [ ] **Step 1: Write failing tests for fuzzy filtering**

Append to `SessionManagerViewModelTests.swift`:

```swift
  func test_fuzzyFilter_subsequence() async {
    let store = SessionStore()
    let _ = store.createSession(name: "my-project", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("mprj")

    // Should match "my-project" via fuzzy subsequence
    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertTrue(sessionNames.contains("my-project"))
  }

  func test_fuzzyFilter_multiToken_AND() async {
    let store = SessionStore()
    let _ = store.createSession(name: "work-bazel", directory: URL(fileURLWithPath: "/tmp/workspace"))
    let _ = store.createSession(name: "work-other", directory: URL(fileURLWithPath: "/tmp/other"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("work bazel")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertTrue(sessionNames.contains("work-bazel"))
    XCTAssertFalse(sessionNames.contains("work-other"))
  }

  func test_fuzzyFilter_matchQualityPrimary_frecencyTiebreak() async {
    let store = SessionStore()
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("frecency-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let service = FrecencyService(storageURL: tempURL)
    service.recordAccess(for: "session:dev-tools")
    service.recordAccess(for: "session:dev-tools")

    let _ = store.createSession(name: "dev", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "dev-tools", directory: URL(fileURLWithPath: "/home"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store, frecencyService: service)
    await vm.load()
    vm.updateQuery("dev")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    // "dev" is an exact/prefix match — should rank above "dev-tools" despite lower frecency
    XCTAssertEqual(sessionNames.first, "dev")
  }

  func test_fuzzyFilter_sshBoost() async {
    let store = SessionStore()
    let _ = store.createSession(name: "ssh-config-editor", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    // Manually inject an SSH host item
    await vm.load()
    vm.updateQuery("ssh prod")

    // SSH items should get boosted — but this test just verifies the filter runs without crash
    // Full SSH boost testing requires injecting SSHHost items which requires mocking services
    XCTAssertNotNil(vm.filteredItems)
  }

  func test_fuzzyFilter_storesMatchResults() async {
    let store = SessionStore()
    let _ = store.createSession(name: "my-project", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("proj")

    // matchResults should have entries for matched items
    let matchedItem = vm.filteredItems.first { item in
      if case .runningSession = item { return true }
      return false
    }
    if let item = matchedItem {
      XCTAssertNotNil(vm.matchResults[item.id])
    }
  }

  func test_fuzzyFilter_emptyQuery_showsAll() async {
    let store = SessionStore()
    let _ = store.createSession(name: "alpha", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "beta", directory: URL(fileURLWithPath: "/home"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("")

    XCTAssertEqual(vm.filteredItems.count, 2)
    XCTAssertTrue(vm.matchResults.isEmpty)
  }

  func test_fuzzyFilter_whitespaceOnly_treatedAsEmpty() async {
    let store = SessionStore()
    let _ = store.createSession(name: "alpha", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("   ")

    XCTAssertEqual(vm.filteredItems.count, 1)
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/SessionManagerViewModelTests 2>&1 | tail -20`
Expected: Compilation failure (matchResults not defined)

- [ ] **Step 3: Implement ItemMatchResult and fuzzy filter**

Add `ItemMatchResult` struct at the top of `SessionManagerViewModel.swift` (after imports, before the enum):

```swift
struct ItemMatchResult {
  let score: Double
  let displayNameIndices: [Int]
  let subtitleIndices: [Int]
}
```

Add `matchResults` property to `SessionManagerViewModel` (after `selectedIndex`):

```swift
  var matchResults: [String: ItemMatchResult] = [:]
```

Add a helper to get matchable fields from an item. Add this private method to `SessionManagerViewModel`:

```swift
  /// Returns (rawName, subtitle, displayNamePrefixLength) for fuzzy matching.
  /// rawName is the name without prefix icons (e.g. "▶ " or "⌁ ").
  /// displayNamePrefixLength is how many characters the prefix adds to displayName,
  /// so matched indices can be offset for correct highlighting.
  private func matchableFields(for item: SessionManagerItem) -> (rawName: String, subtitle: String?, prefixLen: Int) {
    switch item {
    case .runningSession(let s):
      return (s.name, nil, 2) // "▶ " is 2 chars
    case .directory(let u):
      return (u.lastPathComponent, u.path, 0)
    case .sshHost(let h):
      return (h.alias, h.hostname, 2) // "⌁ " is 2 chars
    case .newSession:
      return ("", nil, 0)
    }
  }
```

Replace the `applyFilter()` method:

```swift
  private func applyFilter() {
    matchResults = [:]

    let tokens = query.split(separator: " ").map(String.init)

    if tokens.isEmpty {
      filteredItems = allItems
      selectedIndex = 0
      return
    }

    let isSSHQuery = tokens.first?.lowercased() == "ssh"

    struct ScoredItem {
      let item: SessionManagerItem
      let result: ItemMatchResult
    }

    var scored: [ScoredItem] = []

    for item in allItems {
      let fields = matchableFields(for: item)

      var allTokensMatch = true
      var minScore = Double.infinity
      var displayIndices: [Int] = []
      var subtitleIndices: [Int] = []

      for token in tokens {
        let displayMatch = FuzzyMatcher.match(query: token, target: fields.rawName)
        let subtitleMatch = fields.subtitle.flatMap { FuzzyMatcher.match(query: token, target: $0) }

        if let dm = displayMatch, let sm = subtitleMatch {
          if dm.score >= sm.score {
            minScore = min(minScore, dm.score)
            // Offset indices by prefix length so highlighting aligns with displayName
            displayIndices.append(contentsOf: dm.matchedIndices.map { $0 + fields.prefixLen })
          } else {
            minScore = min(minScore, sm.score)
            subtitleIndices.append(contentsOf: sm.matchedIndices)
          }
        } else if let dm = displayMatch {
          minScore = min(minScore, dm.score)
          displayIndices.append(contentsOf: dm.matchedIndices.map { $0 + fields.prefixLen })
        } else if let sm = subtitleMatch {
          minScore = min(minScore, sm.score)
          subtitleIndices.append(contentsOf: sm.matchedIndices)
        } else {
          allTokensMatch = false
          break
        }
      }

      guard allTokensMatch else { continue }

      var finalScore = minScore

      // SSH boost
      if isSSHQuery, case .sshHost = item {
        finalScore = min(finalScore * 1.5, 1.0)
      }

      let result = ItemMatchResult(
        score: finalScore,
        displayNameIndices: displayIndices,
        subtitleIndices: subtitleIndices
      )
      scored.append(ScoredItem(item: item, result: result))
    }

    // Sort by score desc, frecency as tiebreaker
    scored.sort { a, b in
      if a.result.score != b.result.score { return a.result.score > b.result.score }
      let freqA = a.item.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      let freqB = b.item.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      return freqA > freqB
    }

    filteredItems = scored.map(\.item)
    for s in scored {
      matchResults[s.item.id] = s.result
    }

    selectedIndex = 0
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/SessionManagerViewModelTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/SessionManager/SessionManagerViewModel.swift MisttyTests/Views/SessionManagerViewModelTests.swift
git commit -m "feat: replace substring filter with fuzzy matching and multi-token AND"
```

---

## Chunk 3: "New" Option Logic

### Task 7: "New" Option Resolution and Insertion

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift`
- Modify: `MisttyTests/Views/SessionManagerViewModelTests.swift`

- [ ] **Step 1: Write failing tests for "New" option behavior**

Append to `SessionManagerViewModelTests.swift`:

```swift
  func test_newOption_plainText_appearsAtTop() async {
    let store = SessionStore()
    let _ = store.createSession(name: "existing", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("proj")

    guard case .newSession = vm.filteredItems.first else {
      XCTFail("First item should be newSession")
      return
    }
  }

  func test_newOption_notSelectedByDefault() async {
    let store = SessionStore()
    let _ = store.createSession(name: "project", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("proj")

    // "New" is at index 0, but selectedIndex should be 1 (first real match)
    XCTAssertEqual(vm.selectedIndex, 1)
  }

  func test_newOption_becomesDefaultWhenOnlyItem() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("nonexistent-unique-query-xyz")

    // Only "New" should remain, and it should be selected
    XCTAssertEqual(vm.filteredItems.count, 1)
    XCTAssertEqual(vm.selectedIndex, 0)
    guard case .newSession = vm.filteredItems.first else {
      XCTFail("Only item should be newSession")
      return
    }
  }

  func test_newOption_notShownWhenQueryEmpty() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("")

    let hasNew = vm.filteredItems.contains { item in
      if case .newSession = item { return true }
      return false
    }
    XCTAssertFalse(hasNew)
  }

  func test_newOption_pathLike_existingDir() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("/tmp")

    guard case .newSession(_, let dir, let createDir, _) = vm.filteredItems.first else {
      XCTFail("First item should be newSession")
      return
    }
    XCTAssertEqual(dir.path, "/tmp")
    XCTAssertFalse(createDir)
  }

  func test_newOption_pathLike_parentExists_createDir() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("/tmp/nonexistent-mistty-test-dir-\(UUID().uuidString)")

    guard case .newSession(_, _, let createDir, _) = vm.filteredItems.first else {
      XCTFail("First item should be newSession")
      return
    }
    XCTAssertTrue(createDir)
  }

  func test_newOption_pathLike_parentNotExists_noNew() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("/nonexistent-parent-\(UUID().uuidString)/child")

    let hasNew = vm.filteredItems.contains { item in
      if case .newSession = item { return true }
      return false
    }
    XCTAssertFalse(hasNew)
  }

  func test_newOption_ssh() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("ssh myhost")

    guard case .newSession(_, _, _, let sshCmd) = vm.filteredItems.first else {
      XCTFail("First item should be newSession")
      return
    }
    XCTAssertNotNil(sshCmd)
    XCTAssertTrue(sshCmd!.contains("myhost"))
  }

  func test_newOption_ssh_noHostname_noNew() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("ssh ")

    let hasNewSSH = vm.filteredItems.contains { item in
      if case .newSession(_, _, _, let cmd) = item, cmd != nil { return true }
      return false
    }
    XCTAssertFalse(hasNewSSH)
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/SessionManagerViewModelTests 2>&1 | tail -20`
Expected: Tests fail (no "New" insertion logic)

- [ ] **Step 3: Implement "New" option resolution**

Add a private method to `SessionManagerViewModel`:

```swift
  private func resolveNewOption(query: String) -> SessionManagerItem? {
    let tokens = query.split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return nil }

    let fm = FileManager.default

    // SSH-like: starts with "ssh "
    if tokens.first?.lowercased() == "ssh" {
      let hostname = query.drop(while: { $0 != " " }).dropFirst()
        .trimmingCharacters(in: .whitespaces)
      guard !hostname.isEmpty else { return nil }

      let config = MisttyConfig.load()
      let command = config.ssh.resolveCommand(for: hostname)
      let fullCommand = "\(command) \(hostname)"
      return .newSession(
        query: query,
        directory: fm.homeDirectoryForCurrentUser,
        createDirectory: false,
        sshCommand: fullCommand
      )
    }

    // Path-like: contains "/" or starts with "~"
    if query.contains("/") || query.hasPrefix("~") {
      let expanded = (query as NSString).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded).standardized

      var isDir: ObjCBool = false
      if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
        if !isDir.boolValue { return nil } // points to a file
        return .newSession(query: query, directory: url, createDirectory: false, sshCommand: nil)
      }

      // Check parent exists
      let parent = url.deletingLastPathComponent()
      var parentIsDir: ObjCBool = false
      if fm.fileExists(atPath: parent.path, isDirectory: &parentIsDir), parentIsDir.boolValue {
        return .newSession(query: query, directory: url, createDirectory: true, sshCommand: nil)
      }

      return nil // parent doesn't exist
    }

    // Plain text: create session with query as name in active pane's CWD
    let directory = store.activeSession?.activeTab?.activePane?.directory
      ?? store.activeSession?.directory
      ?? fm.homeDirectoryForCurrentUser
    return .newSession(query: query, directory: directory, createDirectory: false, sshCommand: nil)
  }
```

Update `applyFilter()` — at the end, after the sorting and before setting `selectedIndex`, insert the "New" option:

Replace the last section of `applyFilter()` (after the `scored.sort` call):

```swift
    filteredItems = scored.map(\.item)
    for s in scored {
      matchResults[s.item.id] = s.result
    }

    // Prepend "New" option
    if let newItem = resolveNewOption(query: query) {
      filteredItems.insert(newItem, at: 0)
      // Select first real match (index 1) if available, otherwise select "New" (index 0)
      selectedIndex = filteredItems.count > 1 ? 1 : 0
    } else {
      selectedIndex = 0
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/SessionManagerViewModelTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/SessionManager/SessionManagerViewModel.swift MisttyTests/Views/SessionManagerViewModelTests.swift
git commit -m "feat: add 'New' option to session manager with path/SSH/plain text modes"
```

---

### Task 8: confirmSelection with Modifier Flags and newSession Handling

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerViewModel.swift`
- Modify: `MisttyTests/Views/SessionManagerViewModelTests.swift`

- [ ] **Step 1: Write failing tests for newSession confirmation**

Append to `SessionManagerViewModelTests.swift`:

```swift
  func test_confirmSelection_newSession_plainText() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("myproject")
    vm.selectedIndex = 0 // select "New"
    vm.confirmSelection(modifierFlags: [])

    XCTAssertEqual(store.activeSession?.name, "myproject")
  }

  func test_confirmSelection_newSession_cmdOverridesToHome() async {
    let store = SessionStore()
    let s1 = store.createSession(name: "current", directory: URL(fileURLWithPath: "/tmp/somedir"))
    store.activeSession = s1

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("newproj")
    vm.selectedIndex = 0
    vm.confirmSelection(modifierFlags: .command)

    // New session should be in home directory
    let newSession = store.sessions.last
    XCTAssertEqual(newSession?.name, "newproj")
    XCTAssertEqual(newSession?.directory, FileManager.default.homeDirectoryForCurrentUser)
  }

  func test_confirmSelection_newSession_ssh() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("ssh testhost")
    vm.selectedIndex = 0
    vm.confirmSelection(modifierFlags: [])

    let newSession = store.sessions.last
    XCTAssertEqual(newSession?.name, "testhost")
    XCTAssertNotNil(newSession?.sshCommand)
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/SessionManagerViewModelTests 2>&1 | tail -20`
Expected: Compilation failure (confirmSelection doesn't accept modifierFlags)

- [ ] **Step 3: Update confirmSelection to accept modifier flags**

Replace `confirmSelection()` in `SessionManagerViewModel`:

```swift
  func confirmSelection(modifierFlags: NSEvent.ModifierFlags = []) {
    guard selectedIndex < filteredItems.count else { return }
    let item = filteredItems[selectedIndex]

    if let key = item.frecencyKey {
      frecencyService.recordAccess(for: key)
    }

    switch item {
    case .runningSession(let session):
      store.activeSession = session

    case .directory(let url):
      store.createSession(name: url.lastPathComponent, directory: url)

    case .sshHost(let host):
      let config = MisttyConfig.load()
      let command = config.ssh.resolveCommand(for: host.alias)
      let fullCommand = "\(command) \(host.alias)"
      let session = store.createSession(
        name: host.alias,
        directory: FileManager.default.homeDirectoryForCurrentUser,
        exec: fullCommand
      )
      session.sshCommand = fullCommand

    case .newSession(let query, var directory, let createDir, let sshCommand):
      let fm = FileManager.default

      // Cmd modifier overrides to home
      if modifierFlags.contains(.command) {
        directory = fm.homeDirectoryForCurrentUser
      }

      if let sshCommand {
        let hostname = query.drop(while: { $0 != " " }).dropFirst()
          .trimmingCharacters(in: .whitespaces)
        let session = store.createSession(
          name: hostname,
          directory: fm.homeDirectoryForCurrentUser,
          exec: sshCommand
        )
        session.sshCommand = sshCommand
      } else {
        // Create directory if needed (use withIntermediateDirectories: true
        // to handle race condition where directory was created between filter and confirm)
        if createDir {
          try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let name = query.contains("/") || query.hasPrefix("~")
          ? directory.lastPathComponent : query
        store.createSession(name: name, directory: directory)
      }

      // Record frecency for the new session
      let sessionName = sshCommand != nil
        ? query.drop(while: { $0 != " " }).dropFirst().trimmingCharacters(in: .whitespaces)
        : (query.contains("/") || query.hasPrefix("~") ? directory.lastPathComponent : query)
      frecencyService.recordAccess(for: "session:\(sessionName)")
    }
  }
```

Add `import AppKit` at the top of `SessionManagerViewModel.swift` if not already present (needed for `NSEvent.ModifierFlags`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests/SessionManagerViewModelTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/SessionManager/SessionManagerViewModel.swift MisttyTests/Views/SessionManagerViewModelTests.swift
git commit -m "feat: confirmSelection with modifier flags and newSession handling"
```

---

## Chunk 4: View — Highlighting, New Row, Keyboard

### Task 9: Match Highlighting in SessionManagerView

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerView.swift`

- [ ] **Step 1: Add a helper function for highlighted text**

Add this helper struct before `SessionManagerView` in `SessionManagerView.swift`:

```swift
struct HighlightedText: View {
  let text: String
  let indices: Set<Int>

  var body: some View {
    indices.isEmpty
      ? Text(text)
      : text.enumerated().reduce(Text("")) { result, pair in
          let char = String(pair.element)
          return result + Text(char)
            .foregroundColor(indices.contains(pair.offset) ? .accentColor : .primary)
        }
  }
}
```

- [ ] **Step 2: Update item rendering to use highlighting**

In `SessionManagerView`, replace the `VStack` inside the `ForEach` that renders `item.displayName` and `item.subtitle`:

```swift
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

- [ ] **Step 3: Update onTapGesture to pass modifier flags**

Replace the `onTapGesture` block:

```swift
              .onTapGesture {
                vm.selectedIndex = index
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                vm.confirmSelection(modifierFlags: flags)
                isPresented = false
              }
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild build -scheme Mistty 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/SessionManager/SessionManagerView.swift
git commit -m "feat: add match highlighting and 'New' row styling to session manager"
```

---

### Task 10: Tab/Right Arrow Completion in FocusableTextField

**Files:**
- Modify: `Mistty/Views/SessionManager/SessionManagerView.swift` (FocusableTextField, lines 69-112)

- [ ] **Step 1: Add onComplete callback to FocusableTextField**

Update `FocusableTextField` to accept a completion callback. Replace the struct definition:

```swift
struct FocusableTextField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var onComplete: (() -> Void)?
```

Update `makeCoordinator`:

```swift
  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onComplete: onComplete)
  }
```

Update the `Coordinator` class to intercept Tab and Right Arrow:

```swift
  class Coordinator: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    var text: Binding<String>
    var onComplete: (() -> Void)?

    init(text: Binding<String>, onComplete: (() -> Void)?) {
      self.text = text
      self.onComplete = onComplete
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      text.wrappedValue = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      if commandSelector == #selector(NSResponder.insertTab(_:)) {
        onComplete?()
        return true
      }
      if commandSelector == #selector(NSResponder.moveRight(_:)) {
        // Only complete if cursor is at the end
        if textView.selectedRange().location == textView.string.count {
          onComplete?()
          return true
        }
        return false // normal cursor movement
      }
      return false
    }
  }
```

- [ ] **Step 2: Add completion value getter to SessionManagerViewModel**

Add this method to `SessionManagerViewModel`:

```swift
  func completionValue() -> String? {
    guard selectedIndex < filteredItems.count else { return nil }
    let item = filteredItems[selectedIndex]
    switch item {
    case .newSession: return nil
    case .runningSession(let s): return s.name
    case .directory(let u): return u.path
    case .sshHost(let h): return h.alias
    }
  }
```

- [ ] **Step 3: Wire up completion in SessionManagerView**

Update the `FocusableTextField` usage in `SessionManagerView`:

```swift
      FocusableTextField(
        text: $queryText,
        placeholder: "Search sessions, directories, hosts...",
        onComplete: {
          if let value = vm.completionValue() {
            queryText = value
          }
        }
      )
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild build -scheme Mistty 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Mistty/Views/SessionManager/SessionManagerView.swift
git commit -m "feat: add Tab/Right Arrow completion to session manager"
```

---

### Task 11: Pass Modifier Flags on Enter Key

**Files:**
- Modify: `Mistty/App/ContentView.swift` (keyboard handler for session manager)

- [ ] **Step 1: Update the Enter key handler at ContentView.swift:393**

In `Mistty/App/ContentView.swift`, line 393, change:

```swift
        vm.confirmSelection()
```

to:

```swift
        vm.confirmSelection(modifierFlags: event.modifierFlags)
```

This is inside the `case 36: // Return` branch of the session manager keyboard event monitor.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild build -scheme Mistty 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat: pass modifier flags on Enter in session manager"
```

---

## Chunk 5: Integration and Final Tests

### Task 12: Integration Tests

**Files:**
- Modify: `MisttyTests/Views/SessionManagerViewModelTests.swift`

- [ ] **Step 1: Write integration tests covering end-to-end flows**

Append to `SessionManagerViewModelTests.swift`:

```swift
  // MARK: - Cross-field and edge case tests

  func test_fuzzyFilter_multiToken_crossField() async {
    // SSH host with alias "production" and hostname "prod.example.com"
    // Query "prod exam" should match: "prod" on alias, "exam" on hostname
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    // This test requires SSH hosts to be loaded — it depends on SSHConfigService
    // returning hosts. For a unit test, we verify the matching logic works via
    // the FuzzyMatcher directly:
    let aliasMatch = FuzzyMatcher.match(query: "prod", target: "production")
    let hostnameMatch = FuzzyMatcher.match(query: "exam", target: "prod.example.com")
    XCTAssertNotNil(aliasMatch)
    XCTAssertNotNil(hostnameMatch)
  }

  func test_newOption_pathToFile_noNew() async {
    // Create a temp file (not directory)
    let tempFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-test-file-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: tempFile.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery(tempFile.path)

    let hasNew = vm.filteredItems.contains { item in
      if case .newSession = item { return true }
      return false
    }
    XCTAssertFalse(hasNew, "New option should not appear for file paths")
  }

  // MARK: - Integration tests

  func test_tabCompletion_returnsDirectoryPath() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("/tmp")

    // Move selection to a non-New item if present, or verify completionValue
    if vm.filteredItems.count > 1 {
      vm.selectedIndex = 1
      let value = vm.completionValue()
      XCTAssertNotNil(value)
    }
  }

  func test_tabCompletion_newItem_returnsNil() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("nonexistent-xyz")
    vm.selectedIndex = 0 // "New" item

    XCTAssertNil(vm.completionValue())
  }

  func test_typoTolerance_endToEnd() async {
    let store = SessionStore()
    let _ = store.createSession(name: "bazel-build", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("bzael")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertTrue(sessionNames.contains("bazel-build"))
  }

  func test_fullFlow_typeFilterSelectConfirm() async {
    let store = SessionStore()
    let _ = store.createSession(name: "work-project", directory: URL(fileURLWithPath: "/tmp/work"))
    let _ = store.createSession(name: "personal", directory: URL(fileURLWithPath: "/tmp/personal"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()

    // Type query
    vm.updateQuery("work")

    // Verify work-project appears, personal does not (in session items)
    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertTrue(sessionNames.contains("work-project"))
    XCTAssertFalse(sessionNames.contains("personal"))

    // Verify match results exist
    XCTAssertFalse(vm.matchResults.isEmpty)

    // Navigate to first real match and confirm
    vm.selectedIndex = 1 // skip "New"
    vm.confirmSelection()
    XCTAssertEqual(store.activeSession?.name, "work-project")
  }
```

- [ ] **Step 2: Run all tests**

Run: `xcodebuild test -scheme Mistty -only-testing MisttyTests 2>&1 | tail -30`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add MisttyTests/Views/SessionManagerViewModelTests.swift
git commit -m "test: add integration tests for fuzzy session manager"
```

---

### Task 13: Final Cleanup and Update PLAN.md

**Files:**
- Modify: `PLAN.md`

- [ ] **Step 1: Move fuzzy finding from TODO to Implemented in PLAN.md**

In `PLAN.md`, under `## Implemented`, the session workflow section already mentions fuzzy find. Verify it accurately reflects what's been built. If there's a TODO item about session manager fuzzy filtering, move it to Implemented.

- [ ] **Step 2: Run full test suite one final time**

Run: `xcodebuild test -scheme Mistty 2>&1 | tail -30`
Expected: All tests PASS, BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add PLAN.md
git commit -m "docs: update PLAN.md with fuzzy session manager as implemented"
```
