import AppKit

struct CopyModeState {
  let rows: Int
  let cols: Int
  var cursorRow: Int
  var cursorCol: Int = 0

  // Sub-mode
  var subMode: CopySubMode = .normal
  var anchor: (row: Int, col: Int)?

  // Search
  var searchQuery: String = ""

  // Pending input
  var pendingCount: Int?
  var pendingFindChar: FindCharKind?
  var lastFind: (kind: FindCharKind, char: Character)?
  var pendingG: Bool = false
  var showingHelp: Bool = false

  init(rows: Int, cols: Int, cursorRow: Int? = nil, cursorCol: Int? = nil) {
    self.rows = rows
    self.cols = cols
    self.cursorRow = min(max(cursorRow ?? (rows - 1), 0), rows - 1)
    self.cursorCol = min(max(cursorCol ?? 0, 0), cols - 1)
  }

  // MARK: - Backward compatibility (used by overlay)

  var isSelecting: Bool { subMode == .visual || subMode == .visualLine || subMode == .visualBlock }
  var isSearching: Bool { subMode == .search }

  var selectionRange: (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
    guard isSelecting, let anchor = anchor else { return nil }
    return (anchor, (cursorRow, cursorCol))
  }

  // MARK: - Private movement helpers

  private mutating func moveUp() { cursorRow = max(0, cursorRow - 1) }
  private mutating func moveDown() { cursorRow = min(rows - 1, cursorRow + 1) }
  private mutating func moveLeft() { cursorCol = max(0, cursorCol - 1) }
  private mutating func moveRight() { cursorCol = min(cols - 1, cursorCol + 1) }
  private mutating func moveToLineStart() { cursorCol = 0 }
  private mutating func moveToLineEnd() { cursorCol = cols - 1 }
  private mutating func moveToTop() {
    cursorRow = 0
    cursorCol = 0
  }
  private mutating func moveToBottom() {
    cursorRow = rows - 1
    cursorCol = 0
  }

  // MARK: - Key handling

  mutating func handleKey(
    key: Character,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    lineReader: (Int) -> String?
  ) -> [CopyModeAction] {

    // Help overlay: any key dismisses it (consumed)
    if showingHelp {
      showingHelp = false
      return [.hideHelp]
    }

    // Escape
    if keyCode == 53 {
      return handleEscape()
    }

    // Search mode
    if subMode == .search {
      return handleSearchKey(key: key, keyCode: keyCode)
    }

    // Pending find char: next key is the target character
    if pendingFindChar != nil {
      let actions = handleFindCharTarget(key, lineReader: lineReader)
      clampCursorToLineContent(lineReader: lineReader)
      return actions
    }

    // Pending g: resolve two-key sequence
    if pendingG {
      let actions = handlePendingG(
        key: key, keyCode: keyCode, modifiers: modifiers, lineReader: lineReader)
      clampCursorToLineContent(lineReader: lineReader)
      return actions
    }

    // Digit accumulation
    if let digit = key.wholeNumberValue {
      if digit != 0 || pendingCount != nil {
        pendingCount = (pendingCount ?? 0) * 10 + digit
        return []
      }
      // digit == 0 with no pending count -> line start (fall through)
    }

    let actions = handleNormalKey(
      key: key, keyCode: keyCode, modifiers: modifiers, lineReader: lineReader)
    clampCursorToLineContent(lineReader: lineReader)
    return actions
  }

  // MARK: - Escape

  private mutating func handleEscape() -> [CopyModeAction] {
    switch subMode {
    case .visual, .visualLine, .visualBlock:
      subMode = .normal
      anchor = nil
      return [.enterSubMode(.normal)]
    case .search:
      subMode = .normal
      searchQuery = ""
      return [.cancelSearch, .enterSubMode(.normal)]
    case .normal:
      return [.exitCopyMode]
    }
  }

  // MARK: - Search keys

  private mutating func handleSearchKey(key: Character, keyCode: UInt16) -> [CopyModeAction] {
    if keyCode == 36 {  // Return
      subMode = .normal
      return [.confirmSearch]
    }
    if keyCode == 51 {  // Backspace
      _ = searchQuery.popLast()
      return [.updateSearch(query: searchQuery)]
    }
    searchQuery.append(key)
    return [.updateSearch(query: searchQuery)]
  }

  // MARK: - Normal key dispatch

  private mutating func handleNormalKey(
    key: Character,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    lineReader: (Int) -> String?
  ) -> [CopyModeAction] {
    let hadExplicitCount = pendingCount != nil
    let count = pendingCount ?? 1
    pendingCount = nil

    switch key {
    // Navigation
    case "h": return repeatMotion(count) { $0.moveLeft() }
    case "j": return repeatMotion(count) { $0.moveDown() }
    case "k": return repeatMotion(count) { $0.moveUp() }
    case "l": return repeatMotion(count) { $0.moveRight() }
    case "0":
      moveToLineStart()
      return motionActions()
    case "$":
      moveToLineEnd()
      return motionActions()
    case "G":
      if hadExplicitCount {
        cursorRow = min(max(count - 1, 0), rows - 1)
        cursorCol = 0
      } else {
        moveToBottom()
      }
      return motionActions()
    case "g":
      pendingG = true
      return []

    // Visual modes
    case "v":
      if modifiers.contains(.control) {
        return toggleVisualMode(.visualBlock)
      }
      return toggleVisualMode(.visual)
    case "V":
      return toggleVisualMode(.visualLine)

    // Search
    case "/":
      subMode = .search
      searchQuery = ""
      return [.startSearch]
    case "n":
      if !searchQuery.isEmpty { return [.confirmSearch] }
      return []

    // Find char (restore count so handleFindCharTarget can use it)
    case "f":
      pendingFindChar = .f
      pendingCount = hadExplicitCount ? count : nil
      return []
    case "F":
      pendingFindChar = .F
      pendingCount = hadExplicitCount ? count : nil
      return []
    case "t":
      pendingFindChar = .t
      pendingCount = hadExplicitCount ? count : nil
      return []
    case "T":
      pendingFindChar = .T
      pendingCount = hadExplicitCount ? count : nil
      return []
    case ";": return repeatFindChar(count: count, reverse: false, lineReader: lineReader)
    case ",": return repeatFindChar(count: count, reverse: true, lineReader: lineReader)

    // Word motions
    case "w":
      return wordMotion(count: count, lineReader: lineReader) { line, col in
        WordMotion.nextWordStart(in: line, from: col, bigWord: false)
      }
    case "W":
      return wordMotion(count: count, lineReader: lineReader) { line, col in
        WordMotion.nextWordStart(in: line, from: col, bigWord: true)
      }
    case "b":
      return wordMotionBackward(count: count, lineReader: lineReader) { line, col in
        WordMotion.prevWordStart(in: line, from: col, bigWord: false)
      }
    case "B":
      return wordMotionBackward(count: count, lineReader: lineReader) { line, col in
        WordMotion.prevWordStart(in: line, from: col, bigWord: true)
      }
    case "e":
      return wordMotion(count: count, lineReader: lineReader) { line, col in
        WordMotion.nextWordEnd(in: line, from: col, bigWord: false)
      }
    case "E":
      return wordMotion(count: count, lineReader: lineReader) { line, col in
        WordMotion.nextWordEnd(in: line, from: col, bigWord: true)
      }

    // Yank
    case "y":
      guard isSelecting else { return [] }
      return [.exitCopyMode]

    default:
      return []
    }
  }

  // MARK: - Pending g resolution

  private mutating func handlePendingG(
    key: Character,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    lineReader: (Int) -> String?
  ) -> [CopyModeAction] {
    pendingG = false
    switch key {
    case "g":
      moveToTop()
      return motionActions()
    case "e":
      let count = pendingCount ?? 1
      pendingCount = nil
      return wordMotionBackward(count: count, lineReader: lineReader) { line, col in
        WordMotion.prevWordEnd(in: line, from: col, bigWord: false)
      }
    case "E":
      let count = pendingCount ?? 1
      pendingCount = nil
      return wordMotionBackward(count: count, lineReader: lineReader) { line, col in
        WordMotion.prevWordEnd(in: line, from: col, bigWord: true)
      }
    case "?":
      showingHelp.toggle()
      return showingHelp ? [.showHelp] : [.hideHelp]
    default:
      // Cancel g, process key normally
      return handleNormalKey(
        key: key, keyCode: keyCode, modifiers: modifiers, lineReader: lineReader)
    }
  }

  // MARK: - Visual mode toggling

  private mutating func toggleVisualMode(_ target: CopySubMode) -> [CopyModeAction] {
    if subMode == target {
      subMode = .normal
      anchor = nil
      return [.enterSubMode(.normal)]
    } else {
      if anchor == nil {
        anchor = (cursorRow, cursorCol)
      }
      subMode = target
      return [.enterSubMode(target), .updateSelection]
    }
  }

  // MARK: - Find char

  private mutating func handleFindCharTarget(_ char: Character, lineReader: (Int) -> String?)
    -> [CopyModeAction]
  {
    guard let kind = pendingFindChar else { return [] }
    pendingFindChar = nil
    lastFind = (kind: kind, char: char)

    let count = pendingCount ?? 1
    pendingCount = nil
    return executeFindChar(kind: kind, char: char, count: count, lineReader: lineReader)
  }

  private mutating func repeatFindChar(count: Int, reverse: Bool, lineReader: (Int) -> String?)
    -> [CopyModeAction]
  {
    guard let last = lastFind else { return [] }
    let kind = reverse ? last.kind.reversed : last.kind
    return executeFindChar(kind: kind, char: last.char, count: count, lineReader: lineReader)
  }

  private mutating func executeFindChar(
    kind: FindCharKind, char: Character, count: Int, lineReader: (Int) -> String?
  ) -> [CopyModeAction] {
    guard let line = lineReader(cursorRow) else { return [] }
    let chars = Array(line)

    var found = 0
    var targetCol: Int?

    if kind.isForward {
      let searchStart = min(cursorCol + 1, chars.count)
      for i in searchStart..<chars.count {
        if chars[i] == char {
          found += 1
          if found == count {
            targetCol = (kind == .t) ? i - 1 : i
            break
          }
        }
      }
    } else {
      let searchStart = min(cursorCol - 1, chars.count - 1)
      for i in stride(from: searchStart, through: 0, by: -1) {
        if chars[i] == char {
          found += 1
          if found == count {
            targetCol = (kind == .T) ? i + 1 : i
            break
          }
        }
      }
    }

    if let col = targetCol {
      cursorCol = col
      return motionActions()
    }
    return []
  }

  // MARK: - Movement helpers (private, used by handleKey)

  private mutating func repeatMotion(_ count: Int, _ motion: (inout CopyModeState) -> Void)
    -> [CopyModeAction]
  {
    for _ in 0..<count { motion(&self) }
    return motionActions()
  }

  /// Clamp cursorCol to the last non-whitespace character on the current line.
  private mutating func clampCursorToLineContent(lineReader: (Int) -> String?) {
    guard let line = lineReader(cursorRow) else { return }
    let lastContent = lastNonWhitespaceIndex(in: line)
    if lastContent >= 0 {
      cursorCol = min(cursorCol, lastContent)
    } else {
      cursorCol = 0  // empty/whitespace-only line
    }
  }

  private func lastNonWhitespaceIndex(in line: String) -> Int {
    let chars = Array(line)
    var i = chars.count - 1
    while i >= 0 && chars[i].isWhitespace { i -= 1 }
    return i
  }

  private func motionActions() -> [CopyModeAction] {
    if isSelecting {
      return [.cursorMoved, .updateSelection]
    }
    return [.cursorMoved]
  }

  // MARK: - Word motion helpers

  /// Execute a forward word motion with cross-line wrapping.
  private mutating func wordMotion(
    count: Int,
    lineReader: (Int) -> String?,
    motion: (String, Int) -> Int?
  ) -> [CopyModeAction] {
    for _ in 0..<count {
      guard let line = lineReader(cursorRow) else { break }
      if let newCol = motion(line, cursorCol) {
        cursorCol = newCol
      } else {
        // Wrap to next line
        if cursorRow < rows - 1 {
          cursorRow += 1
          cursorCol = 0
          // Skip leading whitespace on the new line
          if let nextLine = lineReader(cursorRow) {
            let chars = Array(nextLine)
            var i = 0
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            if i < chars.count {
              cursorCol = i
            }
          }
        }
      }
    }
    return motionActions()
  }

  /// Execute a backward word motion with cross-line wrapping
  private mutating func wordMotionBackward(
    count: Int,
    lineReader: (Int) -> String?,
    motion: (String, Int) -> Int?
  ) -> [CopyModeAction] {
    for _ in 0..<count {
      guard let line = lineReader(cursorRow) else { break }
      if let newCol = motion(line, cursorCol) {
        cursorCol = newCol
      } else {
        // Wrap to previous line
        if cursorRow > 0 {
          cursorRow -= 1
          if let prevLine = lineReader(cursorRow) {
            cursorCol = max(0, prevLine.count - 1)
          } else {
            cursorCol = 0
          }
        }
      }
    }
    return motionActions()
  }
}
