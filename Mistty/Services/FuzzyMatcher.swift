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

    guard queryLower.count <= targetLower.count + maxAllowedEdits(queryLength: queryLower.count) else { return nil }

    // Try strict ordered match first
    if let result = strictMatch(query: queryLower, target: targetLower, targetLength: targetChars.count) {
      return result
    }

    // Try typo-tolerant fallback
    return typoMatch(query: queryLower, target: targetLower, targetLength: targetChars.count)
  }

  private static func strictMatch(query: [Character], target: [Character], targetLength: Int) -> FuzzyMatch? {
    var bestScore = -Double.infinity
    var bestIndices: [Int]?

    func search(qi: Int, ti: Int, indices: [Int], score: Double, prevMatchIdx: Int?) {
      if qi == query.count {
        let lengthBonus = 1.0 / Double(max(targetLength, 1))
        let finalScore = score + lengthBonus
        if finalScore > bestScore {
          bestScore = finalScore
          bestIndices = indices
        }
        return
      }

      if target.count - ti < query.count - qi { return }

      for i in ti..<target.count {
        guard target[i] == query[qi] else { continue }

        var bonus: Double = 0.0

        if i == 0 { bonus += prefixBonus }

        if i > 0 && boundaryChars.contains(target[i - 1]) {
          bonus += wordBoundaryBonus
        }

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

    let maxPossible = Double(query.count) * (1.0 + prefixBonus + wordBoundaryBonus + consecutiveBonus) + 1.0
    let normalized = min(max(bestScore / maxPossible, 0.0), 1.0)

    return FuzzyMatch(score: normalized, matchedIndices: indices)
  }

  private static let typoPenalty: Double = 0.3

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
}
