import Foundation

enum CopySubMode: Equatable {
  case normal
  case visual
  case visualLine
  case visualBlock
  case searchForward
  case searchReverse
  case hint
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

// MARK: - Phase 3: Hint mode

enum HintAction: Equatable, Sendable {
  case copy
  case open
}

enum HintSource: Equatable, Sendable {
  case patterns
  case lines
}

enum HintKind: Equatable, Sendable {
  case url
  case email
  case uuid
  case path
  case hash
  case ipv4
  case ipv6
  case envVar
  case number
  case quoted
  case codeSpan
  case line
}

struct HintRange: Equatable {
  let startRow: Int
  /// UTF-16 code-unit offset into the line.
  let startCol: Int
  let endRow: Int  // inclusive
  /// UTF-16 code-unit offset into the line (inclusive).
  let endCol: Int
}

struct HintMatch: Equatable {
  let range: HintRange
  let text: String
  let kind: HintKind
}

struct HintState: Equatable {
  let action: HintAction       // default action from entry key
  let source: HintSource
  var matches: [HintMatch]     // bottom→top, left→right
  var labels: [String]         // index-aligned with matches
  var typedPrefix: String = "" // "" or single char
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
  case enterHintMode(HintAction, HintSource)
  case hintInput(Character)
  case exitHintMode
  case copyText(String)
  case openItem(String)
  case requestHintScan
}

struct ScrollbarState: Equatable {
  var total: UInt64 = 0
  var offset: UInt64 = 0
  var len: UInt64 = 0
}
