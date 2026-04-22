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

struct PopupDefinition: Codable, Sendable, Equatable {
  var name: String
  var command: String
  var shortcut: String?
  var width: Double
  var height: Double
  var closeOnExit: Bool
  var cwdSource: PopupCwdSource

  init(
    name: String,
    command: String,
    shortcut: String? = nil,
    width: Double = 0.8,
    height: Double = 0.8,
    closeOnExit: Bool = true,
    cwdSource: PopupCwdSource = .activePane
  ) {
    self.name = name
    self.command = command
    self.shortcut = shortcut
    self.width = width
    self.height = height
    self.closeOnExit = closeOnExit
    self.cwdSource = cwdSource
  }
}
