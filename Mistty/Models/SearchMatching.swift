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
