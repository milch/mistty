import Foundation

/// Helpers for validating terminal titles received from OSC 0/2 escape
/// sequences (the `GHOSTTY_ACTION_SET_TITLE` callback).
///
/// Shells often set the window title from a `preexec` template echoing the
/// typed command line. When the user types `exit` (or `exit 0`, `exit $PATH`,
/// etc.) the hook fires before the shell actually dies, so the terminal
/// receives a title like `"exit …"` and pins it on the tab just before the
/// pane closes. That's never useful — drop it.
enum TerminalTitle {
  /// Returns `title` trimmed, or `nil` if it should be ignored.
  static func sanitized(_ title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !isExitCommand(trimmed) else { return nil }
    return trimmed
  }

  /// True if `s` is a literal `exit` or `exit <args…>` shell invocation.
  private static func isExitCommand(_ s: String) -> Bool {
    guard s.hasPrefix("exit") else { return false }
    let after = s.index(s.startIndex, offsetBy: 4)
    return after == s.endIndex || s[after].isWhitespace
  }
}
