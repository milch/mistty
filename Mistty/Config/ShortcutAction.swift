import Foundation

enum ShortcutAction: String, CaseIterable, Hashable {
  case newTab               = "new_tab"
  case newTabPlain          = "new_tab_plain"
  case closePane            = "close_pane"
  case closeTab             = "close_tab"
  case closeWindow          = "close_window"
  case windowMode           = "window_mode"
  case copyMode             = "copy_mode"
  case yankHints            = "yank_hints"
  case sessionManager       = "session_manager"
  case toggleSidebar        = "toggle_sidebar"
  case toggleTabBar         = "toggle_tab_bar"
  case reloadConfig         = "reload_config"
  case splitHorizontal      = "split_horizontal"
  case splitHorizontalPlain = "split_horizontal_plain"
  case splitVertical        = "split_vertical"
  case splitVerticalPlain   = "split_vertical_plain"
  case reopenClosedWindow   = "reopen_closed_window"
  case renameTab            = "rename_tab"
  case renameSession        = "rename_session"
  case nextTab              = "next_tab"
  case prevTab              = "prev_tab"
  case nextSession          = "next_session"
  case prevSession          = "prev_session"
  case swapSessionDown      = "swap_session_down"
  case swapSessionUp        = "swap_session_up"
}

extension ShortcutAction {
  static let defaults: [ShortcutAction: [Chord]] = [
    .newTab:               [Chord("cmd+t")!],
    .newTabPlain:          [Chord("cmd+opt+t")!],
    .closePane:            [Chord("cmd+w")!],
    .closeTab:             [Chord("cmd+ctrl+w")!],
    .closeWindow:          [Chord("cmd+shift+w")!],
    .windowMode:           [Chord("cmd+x")!],
    .copyMode:             [Chord("cmd+shift+c")!],
    .yankHints:            [Chord("cmd+shift+y")!],
    .sessionManager:       [Chord("cmd+j")!],
    .toggleSidebar:        [Chord("cmd+s")!],
    .toggleTabBar:         [Chord("cmd+shift+b")!],
    .reloadConfig:         [],
    .splitHorizontal:      [Chord("cmd+d")!],
    .splitHorizontalPlain: [Chord("cmd+opt+d")!],
    .splitVertical:        [Chord("cmd+shift+d")!],
    .splitVerticalPlain:   [Chord("cmd+shift+opt+d")!],
    .reopenClosedWindow:   [Chord("cmd+shift+t")!],
    .renameTab:            [Chord("cmd+shift+r")!],
    .renameSession:        [Chord("cmd+opt+r")!],
    .nextTab:              [Chord("cmd+]")!, Chord("cmd+down")!],
    .prevTab:              [Chord("cmd+[")!, Chord("cmd+up")!],
    .nextSession:          [Chord("cmd+opt+down")!, Chord("cmd+shift+]")!],
    .prevSession:          [Chord("cmd+opt+up")!,   Chord("cmd+shift+[")!],
    .swapSessionDown:      [Chord("cmd+shift+down")!, Chord("cmd+opt+]")!],
    .swapSessionUp:        [Chord("cmd+shift+up")!,   Chord("cmd+opt+[")!],
  ]
}

struct FirePolicy: Equatable {
  /// Every shortcut today gates on this. Carried as a field so future actions
  /// (e.g. global hotkeys) can opt out cleanly.
  var requiresTerminalWindowKey: Bool = true
  /// Cmd+X must fall through to system Cut when a TextField has focus.
  var passThroughWhenTextResponder: Bool = false
  /// Disable while window-mode / copy-mode / session-manager owns input.
  var disabledInModalModes: Bool = false
}

extension ShortcutAction {
  var policy: FirePolicy {
    switch self {
    case .windowMode:
      return FirePolicy(passThroughWhenTextResponder: true)
    case .nextTab, .prevTab,
         .nextSession, .prevSession,
         .swapSessionDown, .swapSessionUp:
      return FirePolicy(disabledInModalModes: true)
    default:
      return FirePolicy()
    }
  }

  var notificationName: Notification.Name {
    switch self {
    case .newTab:               return .misttyNewTab
    case .newTabPlain:          return .misttyNewTabPlain
    case .closePane:            return .misttyClosePane
    case .closeTab:             return .misttyCloseTab
    case .closeWindow:          return .misttyCloseWindow
    case .windowMode:           return .misttyWindowMode
    case .copyMode:             return .misttyCopyMode
    case .yankHints:            return .misttyYankHints
    case .sessionManager:       return .misttySessionManager
    case .toggleSidebar:        return .misttyToggleSidebar
    case .toggleTabBar:         return .misttyToggleTabBar
    case .reloadConfig:         return .misttyReloadConfig
    case .splitHorizontal:      return .misttySplitHorizontal
    case .splitHorizontalPlain: return .misttySplitHorizontalPlain
    case .splitVertical:        return .misttySplitVertical
    case .splitVerticalPlain:   return .misttySplitVerticalPlain
    case .reopenClosedWindow:   return .misttyReopenClosedWindow
    case .renameTab:            return .misttyRenameTab
    case .renameSession:        return .misttyRenameSession
    case .nextTab:              return .misttyNextTab
    case .prevTab:              return .misttyPrevTab
    case .nextSession:          return .misttyNextSession
    case .prevSession:          return .misttyPrevSession
    // The "swap session" actions reuse the existing move-session
    // notifications: moving a session up *is* swapping with its
    // prior neighbour. Keeps the diff small.
    case .swapSessionDown:      return .misttyMoveSessionDown
    case .swapSessionUp:        return .misttyMoveSessionUp
    }
  }
}
