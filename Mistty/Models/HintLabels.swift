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
