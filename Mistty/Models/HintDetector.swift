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
