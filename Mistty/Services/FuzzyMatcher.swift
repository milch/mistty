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

  /// Internal representation: ASCII fast path or Unicode fallback. Paths,
  /// SSH aliases, and hostnames are virtually always ASCII, so the byte
  /// path is the common case and dramatically faster (16-byte SIMD-friendly
  /// compares, constant-time histogram lookups, no grapheme-cluster work).
  fileprivate enum Body {
    case ascii(bytes: [UInt8], counts: [Int])  // counts is fixed size 128
    case unicode(chars: [Character], counts: [Character: Int])

    var count: Int {
      switch self {
      case .ascii(let bytes, _): return bytes.count
      case .unicode(let chars, _): return chars.count
      }
    }
  }

  /// Pre-lowercased query + multiset. Build once per typed token and
  /// reuse across every candidate — without this, each `match` call
  /// repeats the same lowercase / arrayify / histogram work on the same
  /// string thousands of times.
  struct PreparedQuery {
    fileprivate let body: Body
    fileprivate let maxEdits: Int
  }

  /// Pre-lowercased target + multiset. Built once per candidate, reused
  /// across every token in a multi-token query.
  struct PreparedTarget {
    fileprivate let body: Body
  }

  static func prepare(query: String) -> PreparedQuery? {
    guard !query.isEmpty else { return nil }
    let body = makeBody(from: query)
    return PreparedQuery(body: body, maxEdits: maxAllowedEdits(queryLength: body.count))
  }

  static func prepare(target: String) -> PreparedTarget? {
    guard !target.isEmpty else { return nil }
    return PreparedTarget(body: makeBody(from: target))
  }

  static func match(query: PreparedQuery, target: PreparedTarget) -> FuzzyMatch? {
    guard query.body.count <= target.body.count + query.maxEdits else { return nil }

    switch (query.body, target.body) {
    case let (.ascii(qb, qc), .ascii(tb, tc)):
      return matchASCII(
        query: qb, queryCounts: qc, target: tb, targetCounts: tc,
        maxEdits: query.maxEdits)
    case let (.ascii(qb, _), .unicode(tc, tCounts)):
      // Mixed: promote the ASCII side to Character so we go down a single
      // code path. Rare — only when the user types ASCII against a
      // non-ASCII target, or vice versa.
      let qChars = qb.map { Character(Unicode.Scalar($0)) }
      var qCounts: [Character: Int] = [:]
      qCounts.reserveCapacity(qChars.count)
      for c in qChars { qCounts[c, default: 0] += 1 }
      return matchUnicode(
        query: qChars, queryCounts: qCounts, target: tc, targetCounts: tCounts,
        maxEdits: query.maxEdits)
    case let (.unicode(qc, qCounts), .ascii(tb, _)):
      let tChars = tb.map { Character(Unicode.Scalar($0)) }
      var tCounts: [Character: Int] = [:]
      tCounts.reserveCapacity(min(tChars.count, 32))
      for c in tChars { tCounts[c, default: 0] += 1 }
      return matchUnicode(
        query: qc, queryCounts: qCounts, target: tChars, targetCounts: tCounts,
        maxEdits: query.maxEdits)
    case let (.unicode(qc, qCounts), .unicode(tc, tCounts)):
      return matchUnicode(
        query: qc, queryCounts: qCounts, target: tc, targetCounts: tCounts,
        maxEdits: query.maxEdits)
    }
  }

  /// String convenience for callers matching a single (query, target) pair.
  /// Hot-loop callers should use `prepare(...)` and reuse.
  static func match(query: String, target: String) -> FuzzyMatch? {
    guard let pq = prepare(query: query), let pt = prepare(target: target) else { return nil }
    return match(query: pq, target: pt)
  }

  // MARK: - Body construction

  /// Single-pass: detect ASCII while lowercasing into a byte buffer. Falls
  /// back to grapheme-cluster lowercase when any non-ASCII byte is found.
  private static func makeBody(from s: String) -> Body {
    let utf8 = s.utf8
    var bytes: [UInt8] = []
    bytes.reserveCapacity(utf8.count)
    for b in utf8 {
      if b >= 0x80 {
        // Non-ASCII byte — fall back to the grapheme-cluster path. We have
        // to re-do the lowercase via String to handle locale-sensitive case
        // folding correctly (e.g. Turkish dotless i).
        let chars = Array(s.lowercased())
        var counts: [Character: Int] = [:]
        counts.reserveCapacity(min(chars.count, 32))
        for c in chars { counts[c, default: 0] += 1 }
        return .unicode(chars: chars, counts: counts)
      }
      bytes.append(asciiLower(b))
    }
    var counts = [Int](repeating: 0, count: 128)
    for b in bytes { counts[Int(b)] &+= 1 }
    return .ascii(bytes: bytes, counts: counts)
  }

  @inline(__always)
  private static func asciiLower(_ b: UInt8) -> UInt8 {
    // ASCII uppercase A-Z is 0x41–0x5A; set bit 5 to lowercase.
    return (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
  }

  @inline(__always)
  private static func isASCIIBoundary(_ b: UInt8) -> Bool {
    // / - _ . space
    return b == 0x2F || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x20
  }

  // MARK: - ASCII fast path

  private static func matchASCII(
    query: [UInt8], queryCounts: [Int],
    target: [UInt8], targetCounts: [Int],
    maxEdits: Int
  ) -> FuzzyMatch? {
    // Constant-time prefilter: a 128-entry histogram comparison. SIMD on
    // ContiguousArray would compress this further but the loop is so tight
    // the compiler vectorizes it already.
    for i in 0..<128 {
      if queryCounts[i] > targetCounts[i] {
        return typoMatchASCII(query: query, target: target, maxEdits: maxEdits)
      }
    }
    if let result = strictMatchASCII(query: query, target: target) {
      return result
    }
    return typoMatchASCII(query: query, target: target, maxEdits: maxEdits)
  }

  private static func strictMatchASCII(query: [UInt8], target: [UInt8]) -> FuzzyMatch? {
    let qLen = query.count
    let tLen = target.count

    // Pass 1: forward scan — does the query appear as a subsequence at all?
    var qi = 0
    var endIdx = 0
    for i in 0..<tLen {
      if target[i] == query[qi] {
        qi &+= 1
        if qi == qLen {
          endIdx = i &+ 1
          break
        }
      }
    }
    guard qi == qLen else { return nil }

    // Pass 2: backward scan to find the tightest window
    qi = qLen &- 1
    var startIdx = endIdx &- 1
    var i = endIdx &- 1
    while i >= 0 {
      if target[i] == query[qi] {
        qi &-= 1
        if qi < 0 {
          startIdx = i
          break
        }
      }
      i &-= 1
    }

    // Candidate start positions: the tight start + each word boundary.
    // `seen` lets us dedupe in O(1); the previous Array+contains was O(n²)
    // over the boundary count.
    var bestScore = -Double.infinity
    var bestIndices: [Int]?
    var seen = [Bool](repeating: false, count: tLen)
    seen[startIdx] = true
    var starts: [Int] = [startIdx]
    for p in 0..<tLen {
      let isBoundary = p == 0 || isASCIIBoundary(target[p &- 1])
      if isBoundary && !seen[p] {
        seen[p] = true
        starts.append(p)
      }
    }

    for sp in starts {
      if let (score, indices) = greedyMatchASCII(
        query: query, target: target, from: sp, targetLength: tLen)
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

  private static func greedyMatchASCII(
    query: [UInt8], target: [UInt8], from start: Int, targetLength: Int
  ) -> (Double, [Int])? {
    var indices: [Int] = []
    indices.reserveCapacity(query.count)
    var score: Double = 0.0
    var qi = 0
    var prevMatchIdx = -1
    let qLen = query.count

    for i in start..<target.count {
      if qi >= qLen { break }
      if target[i] != query[qi] { continue }

      var bonus: Double = 0.0
      if i == 0 { bonus += prefixBonus }
      if i > 0 && isASCIIBoundary(target[i &- 1]) { bonus += wordBoundaryBonus }
      if prevMatchIdx >= 0 && i == prevMatchIdx &+ 1 { bonus += consecutiveBonus }

      score += 1.0 + bonus
      indices.append(i)
      prevMatchIdx = i
      qi &+= 1
    }

    guard qi == qLen else { return nil }

    let lengthBonus = 1.0 / Double(max(targetLength, 1))
    return (score + lengthBonus, indices)
  }

  private static func typoMatchASCII(query: [UInt8], target: [UInt8], maxEdits: Int)
    -> FuzzyMatch?
  {
    guard maxEdits > 0 else { return nil }

    var bestDistance = Int.max
    var bestWindowStart = 0
    var bestWindowLen = query.count

    let minWindow = max(1, query.count - maxEdits)
    let maxWindow = query.count + maxEdits

    for windowLen in minWindow...maxWindow {
      guard windowLen <= target.count else { continue }
      for start in 0...(target.count - windowLen) {
        let dist = damerauLevenshteinASCII(
          a: query, b: target, bStart: start, bLen: windowLen)
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

  /// DL distance over a window of `b`. Avoids materializing the window into
  /// a fresh array (the old code did `Array(target[start..<start+len])` per
  /// window) by passing offsets — that allocation was a significant chunk
  /// of typoMatch cost.
  private static func damerauLevenshteinASCII(
    a: [UInt8], b: [UInt8], bStart: Int, bLen: Int
  ) -> Int {
    let n = a.count
    let m = bLen
    if n == 0 { return m }
    if m == 0 { return n }

    // Flat row-major DP table; (m+1)-stride. Allocating once is cheaper
    // than the nested Array(repeating:Array(repeating:)) the old code did.
    let stride = m &+ 1
    var dp = [Int](repeating: 0, count: (n &+ 1) * stride)
    for i in 0...n { dp[i * stride] = i }
    for j in 0...m { dp[j] = j }

    for i in 1...n {
      let ai = a[i &- 1]
      let rowBase = i * stride
      let prevRowBase = (i &- 1) * stride
      for j in 1...m {
        let bj = b[bStart &+ j &- 1]
        let cost = ai == bj ? 0 : 1
        var best = dp[prevRowBase &+ j] &+ 1  // deletion
        let ins = dp[rowBase &+ j &- 1] &+ 1  // insertion
        if ins < best { best = ins }
        let sub = dp[prevRowBase &+ j &- 1] &+ cost  // substitution
        if sub < best { best = sub }
        if i > 1, j > 1, ai == b[bStart &+ j &- 2], a[i &- 2] == bj {
          let trans = dp[(i &- 2) * stride &+ j &- 2] &+ 1
          if trans < best { best = trans }
        }
        dp[rowBase &+ j] = best
      }
    }
    return dp[n * stride &+ m]
  }

  // MARK: - Unicode fallback (rare path: non-ASCII inputs)

  private static func matchUnicode(
    query: [Character], queryCounts: [Character: Int],
    target: [Character], targetCounts: [Character: Int],
    maxEdits: Int
  ) -> FuzzyMatch? {
    for (c, needed) in queryCounts {
      if (targetCounts[c] ?? 0) < needed {
        return typoMatch(query: query, target: target, targetLength: target.count)
      }
    }
    if let result = strictMatch(query: query, target: target, targetLength: target.count) {
      return result
    }
    return typoMatch(query: query, target: target, targetLength: target.count)
  }

  private static func strictMatch(query: [Character], target: [Character], targetLength: Int)
    -> FuzzyMatch?
  {
    let qLen = query.count
    let tLen = target.count

    var qi = 0
    var endIdx = 0
    for i in 0..<tLen {
      if target[i] == query[qi] {
        qi += 1
        if qi == qLen { endIdx = i + 1; break }
      }
    }
    guard qi == qLen else { return nil }

    qi = qLen - 1
    var startIdx = endIdx - 1
    for i in stride(from: endIdx - 1, through: 0, by: -1) {
      if target[i] == query[qi] {
        qi -= 1
        if qi < 0 { startIdx = i; break }
      }
    }

    var bestScore = -Double.infinity
    var bestIndices: [Int]?
    var seen = [Bool](repeating: false, count: tLen)
    seen[startIdx] = true
    var starts: [Int] = [startIdx]
    for p in 0..<tLen {
      let isBoundary = p == 0 || boundaryChars.contains(target[p - 1])
      if isBoundary && !seen[p] {
        seen[p] = true
        starts.append(p)
      }
    }

    for sp in starts {
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

  private static func greedyMatch(
    query: [Character], target: [Character], from start: Int, targetLength: Int
  ) -> (Double, [Int])? {
    var indices: [Int] = []
    indices.reserveCapacity(query.count)
    var score: Double = 0.0
    var qi = 0
    var prevMatchIdx = -1

    for i in start..<target.count {
      guard qi < query.count else { break }
      guard target[i] == query[qi] else { continue }

      var bonus: Double = 0.0
      if i == 0 { bonus += prefixBonus }
      if i > 0 && boundaryChars.contains(target[i - 1]) { bonus += wordBoundaryBonus }
      if prevMatchIdx >= 0 && i == prevMatchIdx + 1 { bonus += consecutiveBonus }

      score += 1.0 + bonus
      indices.append(i)
      prevMatchIdx = i
      qi += 1
    }

    guard qi == query.count else { return nil }

    let lengthBonus = 1.0 / Double(max(targetLength, 1))
    return (score + lengthBonus, indices)
  }

  // MARK: - Typo tolerance (Unicode path)

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
          dp[i - 1][j] + 1,
          dp[i][j - 1] + 1,
          dp[i - 1][j - 1] + cost
        )
        if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
          dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + 1)
        }
      }
    }
    return dp[n][m]
  }
}
