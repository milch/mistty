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
}
