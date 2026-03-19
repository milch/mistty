import Foundation

enum CopySubMode: Equatable {
  case normal
  case visual
  case visualLine
  case visualBlock
  case search
}

enum FindCharKind: Equatable {
  case f, F, t, T

  var reversed: FindCharKind {
    switch self {
    case .f: return .F
    case .F: return .f
    case .t: return .T
    case .T: return .t
    }
  }

  var isForward: Bool {
    switch self {
    case .f, .t: return true
    case .F, .T: return false
    }
  }
}

enum CopyModeAction: Equatable {
  case cursorMoved
  case updateSelection
  case yank(text: String)
  case exitCopyMode
  case enterSubMode(CopySubMode)
  case showHelp
  case hideHelp
  case startSearch
  case updateSearch(query: String)
  case confirmSearch
  case cancelSearch
}
