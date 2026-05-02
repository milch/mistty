import Foundation

/// Where a popup pane's initial working directory comes from. `.activePane`
/// preserves the behavior popups have always had; `.session` matches the
/// session's original `cwd`; `.home` opens in `~`, handy for popups that
/// shouldn't carry project context.
enum PopupCwdSource: String, Codable, Sendable, Equatable, CaseIterable {
  case session
  case activePane = "active_pane"
  case home

  var displayName: String {
    switch self {
    case .session: return "Session"
    case .activePane: return "Active pane"
    case .home: return "Home (~)"
    }
  }
}

struct PopupDefinition: Sendable, Equatable {
  var name: String
  var command: String
  /// Raw user-typed shortcut string (e.g. "cmd+shift+x" or empty/nil).
  /// Preserved verbatim for round-trip via `MisttyConfig.save()` and the
  /// Settings text-field binding. Parse failures here are non-fatal: the
  /// popup keeps its raw text but `shortcutChord` is nil so it just won't
  /// bind a chord.
  var shortcutRaw: String?
  var width: Double
  var height: Double
  var closeOnExit: Bool
  var cwdSource: PopupCwdSource
  /// When true (default), Mistty wraps the command in `sh -c '…'` before
  /// handing it to ghostty so multi-statement lines (`cd /foo && nvim`)
  /// survive ghostty's `exec -l {cmd}` step. Set to false if you're already
  /// invoking your own shell (`zsh -c '…'`, `fish -c '…'`, etc.) and don't
  /// want Mistty double-wrapping.
  var shellWrap: Bool

  /// Parsed chord, or nil if `shortcutRaw` is empty / unparseable.
  var shortcutChord: Chord? {
    guard let raw = shortcutRaw, !raw.isEmpty else { return nil }
    return Chord(raw)
  }

  init(
    name: String,
    command: String,
    shortcut: String? = nil,
    width: Double = 0.8,
    height: Double = 0.8,
    closeOnExit: Bool = true,
    cwdSource: PopupCwdSource = .activePane,
    shellWrap: Bool = true
  ) {
    self.name = name
    self.command = command
    self.shortcutRaw = shortcut
    self.width = width
    self.height = height
    self.closeOnExit = closeOnExit
    self.cwdSource = cwdSource
    self.shellWrap = shellWrap
  }
}

extension PopupDefinition: Codable {
  enum CodingKeys: String, CodingKey {
    case name, command, width, height, closeOnExit, cwdSource, shellWrap
    case shortcut       // canonical key on disk; maps to shortcutRaw in memory
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    command = try c.decode(String.self, forKey: .command)
    shortcutRaw = try c.decodeIfPresent(String.self, forKey: .shortcut)
    width = try c.decode(Double.self, forKey: .width)
    height = try c.decode(Double.self, forKey: .height)
    closeOnExit = try c.decode(Bool.self, forKey: .closeOnExit)
    cwdSource = try c.decode(PopupCwdSource.self, forKey: .cwdSource)
    shellWrap = try c.decode(Bool.self, forKey: .shellWrap)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(command, forKey: .command)
    try c.encodeIfPresent(shortcutRaw, forKey: .shortcut)
    try c.encode(width, forKey: .width)
    try c.encode(height, forKey: .height)
    try c.encode(closeOnExit, forKey: .closeOnExit)
    try c.encode(cwdSource, forKey: .cwdSource)
    try c.encode(shellWrap, forKey: .shellWrap)
  }
}
