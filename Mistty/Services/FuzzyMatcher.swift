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
  private static let boundaryChars: Set<Character> = ["/", "-", "_", ".", " "]

  /// Pre-lowercased query plus its character multiset. Build once per typed
  /// token and reuse across every candidate target — without this, each
  /// `match` call repeats the same `lowercased()` + `Array(...)` +
  /// `[Character: Int]` build on the same string thousands of times.
  struct PreparedQuery {
    let chars: [Character]
    fileprivate let charCounts: [Character: Int]
    fileprivate let maxEdits: Int
  }

  /// Pre-lowercased target plus its character multiset. Build once per
  /// candidate string and reuse across every token in a multi-token query.
  struct PreparedTarget {
    let chars: [Character]
    fileprivate let charCounts: [Character: Int]
  }

  static func prepare(query: String) -> PreparedQuery? {
    guard !query.isEmpty else { return nil }
    let lower = Array(query.lowercased())
    var counts: [Character: Int] = [:]
    counts.reserveCapacity(lower.count)
    for c in lower { counts[c, default: 0] += 1 }
    return PreparedQuery(
      chars: lower,
      charCounts: counts,
      maxEdits: maxAllowedEdits(queryLength: lower.count)
    )
  }

  static func prepare(target: String) -> PreparedTarget? {
    guard !target.isEmpty else { return nil }
    let lower = Array(target.lowercased())
    var counts: [Character: Int] = [:]
    counts.reserveCapacity(min(lower.count, 32))
    for c in lower { counts[c, default: 0] += 1 }
    return PreparedTarget(chars: lower, charCounts: counts)
  }

  static func match(query: PreparedQuery, target: PreparedTarget) -> FuzzyMatch? {
    guard query.chars.count <= target.chars.count + query.maxEdits else { return nil }

    // Prefilter: every char the query needs must appear in target with at
    // least the required multiplicity. Comparing precomputed multisets means
    // no per-call dict mutation — just a small read-only loop over the
    // (usually short) distinct query chars.
    for (c, needed) in query.charCounts {
      if (target.charCounts[c] ?? 0) < needed {
        return typoMatch(
          query: query.chars, target: target.chars, targetLength: target.chars.count)
      }
    }

    if let result = strictMatch(
      query: query.chars, target: target.chars, targetLength: target.chars.count)
    {
      return result
    }
    return typoMatch(query: query.chars, target: target.chars, targetLength: target.chars.count)
  }

  /// String convenience for callers matching a single (query, target) pair.
  /// Hot-loop callers should use `prepare(query:)` / `prepare(target:)` and
  /// call the `PreparedQuery`/`PreparedTarget` overload directly.
  static func match(query: String, target: String) -> FuzzyMatch? {
    guard let pq = prepare(query: query), let pt = prepare(target: target) else { return nil }
    return match(query: pq, target: pt)
  }

  /// Two-pass greedy algorithm (like fzf):
  /// Pass 1: scan left-to-right to find the rightmost valid subsequence match
  /// Pass 2: scan right-to-left from the end of pass 1 to find the tightest window
  /// Then score the matched positions within that window
  private static func strictMatch(query: [Character], target: [Character], targetLength: Int)
    -> FuzzyMatch?
  {
    let qLen = query.count
    let tLen = target.count

    // Pass 1: forward scan — find if a subsequence match exists at all
    // and record the end position
    var qi = 0
    var endIdx = 0
    for i in 0..<tLen {
      if target[i] == query[qi] {
        qi += 1
        if qi == qLen {
          endIdx = i + 1
          break
        }
      }
    }
    guard qi == qLen else { return nil }

    // Pass 2: backward scan from endIdx to find tightest window
    qi = qLen - 1
    var startIdx = endIdx - 1
    for i in stride(from: endIdx - 1, through: 0, by: -1) {
      if target[i] == query[qi] {
        qi -= 1
        if qi < 0 {
          startIdx = i
          break
        }
      }
    }

    // Now find the best match within the window [startIdx, endIdx) using
    // a bounded search. We also try starting from each word boundary
    // within the target to find boundary-aligned matches.
    var bestScore = -Double.infinity
    var bestIndices: [Int]?

    // Collect candidate start positions: the tight window start + all word boundaries
    var startPositions = [startIdx]
    for i in 0..<tLen {
      if i == 0 || boundaryChars.contains(target[i - 1]) {
        if !startPositions.contains(i) {
          startPositions.append(i)
        }
      }
    }

    for sp in startPositions {
      if let (score, indices) = greedyMatch(
        query: query, target: target, from: sp, targetLength: targetLength)
      {
        if score > bestScore {
          bestScore = score
          bestIndices = indices
        }
      }
    }

    guard let indices = bestIndices else { return nil }

    let maxPossible =
      Double(qLen) * (1.0 + prefixBonus + wordBoundaryBonus + consecutiveBonus) + 1.0
    let normalized = min(max(bestScore / maxPossible, 0.0), 1.0)

    return FuzzyMatch(score: normalized, matchedIndices: indices)
  }

  /// Greedy forward match from a given start position, preferring consecutive and boundary matches
  private static func greedyMatch(
    query: [Character], target: [Character], from start: Int, targetLength: Int
  ) -> (Double, [Int])? {
    var indices: [Int] = []
    var score: Double = 0.0
    var qi = 0
    var prevMatchIdx: Int? = nil

    for i in start..<target.count {
      guard qi < query.count else { break }
      guard target[i] == query[qi] else { continue }

      var bonus: Double = 0.0
      if i == 0 { bonus += prefixBonus }
      if i > 0 && boundaryChars.contains(target[i - 1]) { bonus += wordBoundaryBonus }
      if let prev = prevMatchIdx, i == prev + 1 { bonus += consecutiveBonus }

      score += 1.0 + bonus
      indices.append(i)
      prevMatchIdx = i
      qi += 1
    }

    guard qi == query.count else { return nil }

    let lengthBonus = 1.0 / Double(max(targetLength, 1))
    return (score + lengthBonus, indices)
  }

  // MARK: - Typo tolerance

  private static let typoPenalty: Double = 0.3

  private static func maxAllowedEdits(queryLength: Int) -> Int {
    switch queryLength {
    case 0...3: return 0
    case 4...6: return 1
    default: return 2
    }
  }

  private static func typoMatch(query: [Character], target: [Character], targetLength: Int)
    -> FuzzyMatch?
  {
    let maxEdits = maxAllowedEdits(queryLength: query.count)
    guard maxEdits > 0 else { return nil }

    var bestDistance = Int.max
    var bestWindowStart = 0
    var bestWindowLen = query.count

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
          bestWindowLen = windowLen
        }
      }
    }

    guard bestDistance <= maxEdits else { return nil }

    let indices = Array(bestWindowStart..<(bestWindowStart + bestWindowLen))

    let baseScore = Double(query.count - bestDistance) / Double(max(query.count, 1))
    let score = baseScore * typoPenalty

    let normalized = min(max(score, 0.0), 1.0)

    return FuzzyMatch(score: normalized, matchedIndices: indices)
  }

  /// Standard Damerau-Levenshtein distance (optimal string alignment variant)
  private static func damerauLevenshtein(_ a: [Character], _ b: [Character]) -> Int {
    let n = a.count
    let m = b.count
    if n == 0 { return m }
    if m == 0 { return n }

    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { dp[i][0] = i }
    for j in 0...m { dp[0][j] = j }

    for i in 1...n {
      for j in 1...m {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        dp[i][j] = min(
          dp[i - 1][j] + 1,  // deletion
          dp[i][j - 1] + 1,  // insertion
          dp[i - 1][j - 1] + cost  // substitution
        )
        // Transposition (always costs 1 edit)
        if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
          dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + 1)
        }
      }
    }
    return dp[n][m]
  }
}
