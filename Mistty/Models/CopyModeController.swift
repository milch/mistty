import AppKit
import GhosttyKit

/// Orchestrates copy-mode interaction against a terminal surface: entering,
/// scrolling, search, hint scanning, and yanking. Pulled out of `ContentView`
/// so the coordinate math (the riskiest, least-tested code in the app) runs
/// against a `TerminalContentReading` abstraction and can be unit-tested with
/// a fake. The pure value types it builds on — `CopyModeState`,
/// `SearchMatching`, `CopyModeYank`, `HintDetector` — are already tested; this
/// is the glue that reads the live surface and feeds them.
///
/// Stateless: every method takes the `CopyModeState` it operates on plus the
/// `reader`. `ContentView` keeps the NSEvent-monitor plumbing, active-pane
/// lookup, and per-pane `copyModeState` storage.
@MainActor
final class CopyModeController {
  /// Config snapshot resolved once per keystroke by the caller. Both fields
  /// come from `MisttyConfig.current` (which is what `.load()` returns too —
  /// it's a cached value, no disk read).
  struct Config {
    var scrolloff: Int
    var hintAlphabet: String
    var hintUppercaseAction: HintAction
  }

  /// How the caller should treat the key event after `handleKey`.
  enum KeyResult {
    /// Consume the event and persist the mutated `state`.
    case consume
    /// Let the event fall through to the terminal / other monitors.
    case passThrough
    /// Copy mode ended; the caller scrolls to bottom and clears state.
    case exit
  }

  // MARK: - Entry

  /// Build the initial copy-mode state for a freshly-entered pane: read the
  /// grid size and cursor position, pin the viewport so streaming output
  /// can't scroll the selection away, and anchor the cursor mid-viewport
  /// when the user entered while looking at scrollback.
  func makeInitialState(reader: TerminalContentReading) -> CopyModeState {
    var rows = 24
    var cols = 80
    var cursorRow: Int?
    var cursorCol: Int?
    if let size = reader.viewportGridSize() {
      rows = size.rows
      cols = size.cols
    }
    if let pos = reader.cursorPosition() {
      cursorRow = pos.row
      cursorCol = pos.col
    }

    // Freeze the viewport on entry. Ghostty's viewport defaults to `.active`
    // (auto-follows the live edge), so streaming output keeps scrolling the
    // visible area and copy-mode selections become impossible. pinViewport
    // transitions `.active` → `.pin` at the current top row, no visual shift.
    reader.pinViewport()

    // When the user enters copy mode while looking at scrollback, the live
    // cursor row is below the visible viewport and `cursorPosition()` clamps
    // the copy-mode cursor to the viewport bottom — so the first j/k snaps
    // the view away. Detect that via the scrollbar offset (`< maxOffset` ⇔
    // user is in scrollback) and anchor mid-viewport instead.
    let sb = reader.scrollbarState
    let maxOffset = sb.total > sb.len ? sb.total - sb.len : 0
    if sb.offset < maxOffset {
      cursorRow = rows / 2
      cursorCol = 0
    }

    return CopyModeState(rows: rows, cols: cols, cursorRow: cursorRow, cursorCol: cursorCol)
  }

  /// Scroll back to the live edge — used on copy-mode exit.
  func scrollToBottom(reader: TerminalContentReading) {
    reader.runBindingAction("scroll_to_bottom")
  }

  // MARK: - Scrolling

  /// Scroll the viewport by `delta` rows (positive = toward the live edge;
  /// negative = into scrollback). Returns the actual delta applied after
  /// clamping (smaller in absolute value if the scroll hit the top of
  /// scrollback or the live edge).
  @discardableResult
  func scrollViewport(
    _ state: inout CopyModeState, delta: Int, reader: TerminalContentReading
  ) -> Int {
    reader.runBindingAction("scroll_page_lines:\(delta)")
    // Update scrollbar offset synchronously — the async callback will
    // eventually arrive, but subsequent search coordinate conversion needs
    // the correct offset immediately.
    let oldOffset = reader.scrollbarState.offset
    let total = reader.scrollbarState.total
    let len = reader.scrollbarState.len
    // Clamp the same way ghostty does internally: offset can't go below 0
    // (top of scrollback) or above total-len (live area pinned to bottom).
    let maxOffset = total > len ? total - len : 0
    let target = Int64(oldOffset) + Int64(delta)
    let clampedOffset = UInt64(max(0, min(Int64(maxOffset), target)))
    reader.scrollbarState.offset = clampedOffset
    // Adjust the anchor by the *actual* offset change, not the requested
    // delta — scrolls ghostty refused (top/bottom of scrollable area) would
    // otherwise drift the anchor away from its true screen position, and on
    // yank the runaway anchor selects too much or too little.
    let actualDelta = Int(clampedOffset) - Int(oldOffset)
    if let anchor = state.anchor {
      state.anchor = (row: anchor.row - actualDelta, col: anchor.col)
    }
    state.scrollGeneration &+= 1
    return actualDelta
  }

  // MARK: - Search

  /// Run a single cached scan over the full scrollback (rebuilt only when the
  /// query or row count changes), jump to the next/previous match via
  /// `SearchMatching`, and center it in the viewport.
  func runSearch(
    _ state: inout CopyModeState, direction: SearchDirection, reader: TerminalContentReading
  ) {
    guard !state.searchQuery.isEmpty,
      let cols = reader.viewportGridSize()?.cols
    else { return }

    let scrollbar = reader.scrollbarState
    let totalRows = Int(scrollbar.total)
    guard totalRows > 0 else { return }

    if state.searchMatchesQuery != state.searchQuery
      || state.searchMatchesTotalRows != totalRows
    {
      var matches: [SearchMatch] = []
      for row in 0..<totalRows {
        guard let line = readLineByScreenRow(row, reader: reader) else { continue }
        var searchStart = line.startIndex
        while let range = line.range(
          of: state.searchQuery, options: .caseInsensitive,
          range: searchStart..<line.endIndex)
        {
          matches.append(SearchMatch(
            row: row, col: line.distance(from: line.startIndex, to: range.lowerBound)))
          searchStart = range.upperBound
        }
      }
      state.searchMatches = matches
      state.searchMatchesQuery = state.searchQuery
      state.searchMatchesTotalRows = totalRows
    }

    let cursorScreenRow = state.cursorRow + Int(scrollbar.offset)
    guard let target = SearchMatching.nextMatch(
      after: cursorScreenRow, col: state.cursorCol,
      in: state.searchMatches, forward: direction == .forward)
    else {
      state.searchMatchTotal = nil
      state.searchMatchIndex = nil
      return
    }

    // Center the match in the viewport.
    let viewportRows = Int(scrollbar.len)
    let targetOffset = max(0, min(target.row - viewportRows / 2, totalRows - viewportRows))
    reader.runBindingAction("scroll_to_row:\(targetOffset)")
    // Front-run the async scrollbar callback so consecutive n/N compute
    // correct screen coordinates.
    reader.scrollbarState.offset = UInt64(targetOffset)

    state.cursorRow = target.row - targetOffset
    state.cursorCol = min(target.col, cols - 1)
    state.desiredCol = nil
    state.searchMatchTotal = state.searchMatches.count
    state.searchMatchIndex = SearchMatching.index(of: target, in: state.searchMatches)
  }

  /// Read a line by screen row, preferring VIEWPORT reading when the row is
  /// visible (consistent with the highlight overlay, which uses VIEWPORT).
  private func readLineByScreenRow(_ screenRow: Int, reader: TerminalContentReading) -> String? {
    let scrollbar = reader.scrollbarState
    let viewportRow = screenRow - Int(scrollbar.offset)
    if viewportRow >= 0 && viewportRow < Int(scrollbar.len) {
      return reader.readRow(viewportRow, pointTag: GHOSTTY_POINT_VIEWPORT)
    }
    return reader.readRow(screenRow, pointTag: GHOSTTY_POINT_SCREEN)
  }

  // MARK: - Hints

  func populateHintMatches(
    _ state: inout CopyModeState, source: HintSource, reader: TerminalContentReading
  ) {
    var lines: [String] = []
    for row in 0..<state.rows {
      lines.append(reader.readRow(row, pointTag: GHOSTTY_POINT_VIEWPORT) ?? "")
    }
    state.setHintMatches(HintDetector.detect(lines: lines, source: source))
  }

  // MARK: - Yank

  /// Extract the selected text (visual / line / block) for the current
  /// selection, or nil if there's no selection. Pure coordinate→text mapping;
  /// the caller writes the pasteboard.
  func yankText(_ state: CopyModeState, reader: TerminalContentReading) -> String? {
    guard let anchor = state.anchor,
      let cols = reader.viewportGridSize()?.cols
    else { return nil }

    // When the anchor scrolled out of the viewport, read in SCREEN coords and
    // shift both endpoints by the scrollback offset.
    let useScreenCoords = anchor.row < 0 || anchor.row >= state.rows
    let tag: ghostty_point_tag_e = useScreenCoords ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
    let offset = useScreenCoords ? Int(reader.scrollbarState.offset) : 0

    switch state.subMode {
    case .visual:
      let (top, bottom) = CopyModeYank.normalize(
        anchor: (row: anchor.row + offset, col: anchor.col),
        cursor: (row: state.cursorRow + offset, col: state.cursorCol)
      )
      return reader.readText(
        startRow: top.row, startCol: top.col,
        endRow: bottom.row, endCol: bottom.col,
        rectangle: false, pointTag: tag)

    case .visualLine:
      let minRow = min(anchor.row, state.cursorRow)
      let maxRow = max(anchor.row, state.cursorRow)
      return reader.readText(
        startRow: minRow + offset, startCol: 0,
        endRow: maxRow + offset, endCol: cols - 1,
        rectangle: false, pointTag: tag)

    case .visualBlock:
      let minRow = min(anchor.row, state.cursorRow)
      let maxRow = max(anchor.row, state.cursorRow)
      let minCol = min(anchor.col, state.cursorCol)
      let logicalRightCol = max(anchor.col, state.cursorCol)
      var lines: [String] = []
      for row in minRow...maxRow {
        guard let line = reader.readRow(row + offset, pointTag: tag) else { continue }
        let contentEnd = WordMotion.lastNonWhitespaceIndex(in: line)
        guard contentEnd >= minCol else {
          lines.append("")
          continue
        }
        let rightCol = min(logicalRightCol, contentEnd)
        let chars = Array(line)
        let start = min(minCol, chars.count)
        let end = min(rightCol + 1, chars.count)
        lines.append(start < end ? String(chars[start..<end]) : "")
      }
      return lines.joined(separator: "\n")

    default:
      return nil
    }
  }

  // MARK: - Keystroke dispatch

  /// Process one keystroke against the focused pane's copy-mode `state`.
  /// Mutates `state` in place and performs pasteboard / open side-effects.
  /// `key`/`keyStr` are extracted by the caller from the NSEvent.
  func handleKey(
    key: Character, keyStr: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
    state: inout CopyModeState, config: Config, reader: TerminalContentReading
  ) -> KeyResult {
    // Pass through system shortcuts (Cmd+*) when not searching.
    if modifiers.contains(.command) && !state.isSearching {
      return .passThrough
    }

    // Let Ctrl-h/j/k/l reach the pane-nav monitor so the user can switch
    // focus while copy mode stays parked on this pane (it resumes when they
    // navigate back). All other Ctrl-* keys keep being handled here.
    let onlyCtrl = modifiers.intersection(.deviceIndependentFlagsMask) == .control
    if onlyCtrl, !state.isSearching,
      ["h", "j", "k", "l"].contains(Character(keyStr.lowercased()))
    {
      return .passThrough
    }

    let lineReader: (Int) -> String? = { reader.readRow($0, pointTag: GHOSTTY_POINT_VIEWPORT) }

    let prevCursorRow = state.cursorRow
    let actions = state.handleKey(
      key: key, keyCode: keyCode, modifiers: modifiers, lineReader: lineReader)

    for action in actions {
      switch action {
      case .cursorMoved:
        break  // Position already in state
      case .updateSelection:
        break  // Selection derived from state
      case .exitCopyMode:
        // Yank before exiting if there's a selection.
        if state.isSelecting, let text = yankText(state, reader: reader), !text.isEmpty {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
        return .exit
      case .enterSubMode:
        break  // Sub-mode already in state
      case .showHelp, .hideHelp:
        break  // showingHelp already in state
      case .startSearch:
        break  // subMode already set to search
      case .updateSearch:
        break  // searchQuery already updated
      case .confirmSearch:
        runSearch(&state, direction: state.searchDirection, reader: reader)
      case .cancelSearch:
        break  // Already handled in state
      case .searchNext:
        runSearch(&state, direction: state.searchDirection, reader: reader)
      case .searchPrev:
        let reversed: SearchDirection = state.searchDirection == .forward ? .reverse : .forward
        runSearch(&state, direction: reversed, reader: reader)
      case .scroll(let deltaRows):
        scrollViewport(&state, delta: deltaRows, reader: reader)
        if state.isHinting, let source = state.hint?.source {
          populateHintMatches(&state, source: source, reader: reader)
        }
      case .scrollToTop:
        let offset = Int(reader.scrollbarState.offset)
        if offset > 0 {
          scrollViewport(&state, delta: -offset, reader: reader)
        }
        if state.isHinting, let source = state.hint?.source {
          populateHintMatches(&state, source: source, reader: reader)
        }
      case .scrollToBottom:
        let sb = reader.scrollbarState
        let maxOffset = sb.total > sb.len ? sb.total - sb.len : 0
        let delta = Int(Int64(maxOffset) - Int64(sb.offset))
        if delta != 0 {
          scrollViewport(&state, delta: delta, reader: reader)
        }
        if state.isHinting, let source = state.hint?.source {
          populateHintMatches(&state, source: source, reader: reader)
        }
      case .enterHintMode(let action, let source):
        state.applyHintEntry(
          action: action, source: source,
          uppercaseAction: config.hintUppercaseAction, alphabet: config.hintAlphabet)
      case .requestHintScan:
        let source = state.hint?.source ?? .patterns
        populateHintMatches(&state, source: source, reader: reader)
      case .hintInput:
        break  // typedPrefix already set in state
      case .exitHintMode:
        break  // subMode already reset
      case .copyText(let text):
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      case .openItem(let text):
        if let url = URL(string: text), url.scheme != nil {
          NSWorkspace.shared.open(url)
        } else {
          let proc = Process()
          proc.launchPath = "/usr/bin/open"
          proc.arguments = [text]
          try? proc.run()
        }
      case .needsContinuation:
        let continuationActions = state.continuePendingMotion(lineReader: lineReader)
        for contAction in continuationActions {
          switch contAction {
          case .scroll(let delta):
            scrollViewport(&state, delta: delta, reader: reader)
          case .needsContinuation:
            let more = state.continuePendingMotion(lineReader: lineReader)
            for a in more {
              if case .scroll(let d) = a {
                scrollViewport(&state, delta: d, reader: reader)
              }
            }
          default:
            break
          }
        }
      }
    }

    // Scrolloff: keep N rows of context visible above/below the cursor when
    // vertical motions land near a viewport edge. Skips hint/search modes
    // (their cursor positions aren't user-driven navigation) and moves that
    // didn't change the row.
    if config.scrolloff > 0,
      !state.isHinting, !state.isSearching,
      state.cursorRow != prevCursorRow
    {
      let r = state.cursorRow
      let bottomEdge = state.rows - 1 - config.scrolloff
      if r > bottomEdge {
        let actual = scrollViewport(&state, delta: r - bottomEdge, reader: reader)
        state.cursorRow -= actual
      } else if r < config.scrolloff {
        let actual = scrollViewport(&state, delta: r - config.scrolloff, reader: reader)
        state.cursorRow -= actual
      }
    }

    return .consume
  }
}
