import Foundation

enum CopySubMode: Equatable {
  case normal
  case visual
  case visualLine
  case visualBlock
  case searchForward
  case searchReverse
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

enum SearchDirection: Equatable {
  case forward
  case reverse
}

enum PendingMotion: Equatable {
  case wordForward(bigWord: Bool)
  case wordBackward(bigWord: Bool)
  case wordEndForward(bigWord: Bool)
  case wordEndBackward(bigWord: Bool)
  case lineDown
  case lineUp
}

struct ContinuationState: Equatable {
  let motion: PendingMotion
  let remaining: Int
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
  case scroll(deltaRows: Int)
  case needsContinuation
  case searchNext
  case searchPrev
}
