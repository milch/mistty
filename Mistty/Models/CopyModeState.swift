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

  /// Vim "desired column" — remembered during vertical movement (j/k).
  /// Set to Int.max by $ to mean "end of line". Reset by horizontal motions.
  var desiredCol: Int?

  // Phase 2: Scrollback & search
  var searchDirection: SearchDirection = .forward
  var searchMatchIndex: Int?
  var searchMatchTotal: Int?
  var pendingContinuation: ContinuationState?
  /// Incremented on every scroll. Forces SwiftUI re-render of CopyModeOverlay
  /// because the struct value changes, even when cursorRow/cursorCol don't
  /// (e.g., j at bottom row scrolls viewport but cursor stays at row 23).
  var scrollGeneration: Int = 0
  var hint: HintState?

  init(rows: Int, cols: Int, cursorRow: Int? = nil, cursorCol: Int? = nil) {
    self.rows = rows
    self.cols = cols
    self.cursorRow = min(max(cursorRow ?? (rows - 1), 0), rows - 1)
    self.cursorCol = min(max(cursorCol ?? 0, 0), cols - 1)
  }

  // MARK: - Backward compatibility (used by overlay)

  var isSelecting: Bool { subMode == .visual || subMode == .visualLine || subMode == .visualBlock }
  var isSearching: Bool { subMode == .searchForward || subMode == .searchReverse }
  var isHinting: Bool { subMode == .hint }

  var selectionRange: (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
    guard isSelecting, let anchor = anchor else { return nil }
    return (anchor, (cursorRow, cursorCol))
  }

  // MARK: - Private movement helpers

  /// Move vertically by delta rows. Returns scroll overflow (0 = no scroll needed).
  private mutating func moveVertical(delta: Int) -> Int {
    let targetRow = cursorRow + delta
    if targetRow < 0 {
      cursorRow = 0
      return targetRow  // negative = scroll up
    } else if targetRow >= rows {
      cursorRow = rows - 1
      return targetRow - (rows - 1)  // positive = scroll down
    } else {
      cursorRow = targetRow
      return 0
    }
  }

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

    // Hint submode
    if subMode == .hint {
      if keyCode == 53 { return handleEscape() }  // Escape works
      if modifiers.contains(.control) {
        // Let paging (Ctrl-d/u/f/b) fall through to normal handling so the
        // viewport scrolls and the hint overlay re-scans.
        return handleNormalKey(key: key, keyCode: keyCode, modifiers: modifiers, lineReader: lineReader)
      }
      return handleHintKey(key: key)
    }

    // Escape
    if keyCode == 53 {
      return handleEscape()
    }

    // Search mode
    if isSearching {
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
      pendingContinuation = nil
      return [.enterSubMode(.normal)]
    case .searchForward, .searchReverse:
      subMode = .normal
      searchQuery = ""
      pendingContinuation = nil
      return [.cancelSearch, .enterSubMode(.normal)]
    case .normal:
      pendingContinuation = nil
      return [.exitCopyMode]
    case .hint:
      subMode = .normal
      hint = nil
      pendingContinuation = nil
      return [.exitHintMode, .enterSubMode(.normal)]
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

    // Most motions reset desiredCol; j/k/$ override below
    let savedDesiredCol = desiredCol
    desiredCol = nil

    // Ctrl-key paging commands
    if modifiers.contains(.control) {
      switch key {
      case "d":
        let delta = count * (rows / 2)
        return [.scroll(deltaRows: delta), .cursorMoved]
      case "u":
        let delta = count * (rows / 2)
        return [.scroll(deltaRows: -delta), .cursorMoved]
      case "f":
        let delta = count * rows
        return [.scroll(deltaRows: delta), .cursorMoved]
      case "b":
        let delta = count * rows
        return [.scroll(deltaRows: -delta), .cursorMoved]
      default:
        break
      }
    }

    switch key {
    // Navigation
    case "h": return repeatMotion(count) { $0.moveLeft() }
    case "j":
      cursorCol = savedDesiredCol ?? cursorCol
      desiredCol = savedDesiredCol ?? cursorCol
      let scrollDelta = moveVertical(delta: count)
      var result = motionActions()
      if scrollDelta != 0 {
        result.insert(.scroll(deltaRows: scrollDelta), at: 0)
      }
      return result
    case "k":
      cursorCol = savedDesiredCol ?? cursorCol
      desiredCol = savedDesiredCol ?? cursorCol
      let scrollDelta = moveVertical(delta: -count)
      var result = motionActions()
      if scrollDelta != 0 {
        result.insert(.scroll(deltaRows: scrollDelta), at: 0)
      }
      return result
    case "l": return repeatMotion(count) { $0.moveRight() }
    case "0":
      moveToLineStart()
      return motionActions()
    case "$":
      desiredCol = Int.max
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
      subMode = .searchForward
      searchDirection = .forward
      searchQuery = ""
      return [.startSearch]
    case "?":
      subMode = .searchReverse
      searchDirection = .reverse
      searchQuery = ""
      return [.startSearch]
    case "n":
      if !searchQuery.isEmpty { return [.searchNext] }
      return []
    case "N":
      if !searchQuery.isEmpty { return [.searchPrev] }
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
      return wordMotion(count: count, pendingMotionType: .wordForward(bigWord: false), lineReader: lineReader) { line, col in
        WordMotion.nextWordStart(in: line, from: col, bigWord: false)
      }
    case "W":
      return wordMotion(count: count, pendingMotionType: .wordForward(bigWord: true), lineReader: lineReader) { line, col in
        WordMotion.nextWordStart(in: line, from: col, bigWord: true)
      }
    case "b":
      return wordMotionBackward(count: count, pendingMotionType: .wordBackward(bigWord: false), lineReader: lineReader) { line, col in
        WordMotion.prevWordStart(in: line, from: col, bigWord: false)
      }
    case "B":
      return wordMotionBackward(count: count, pendingMotionType: .wordBackward(bigWord: true), lineReader: lineReader) { line, col in
        WordMotion.prevWordStart(in: line, from: col, bigWord: true)
      }
    case "e":
      return wordMotion(count: count, pendingMotionType: .wordEndForward(bigWord: false), lineReader: lineReader) { line, col in
        WordMotion.nextWordEnd(in: line, from: col, bigWord: false)
      }
    case "E":
      return wordMotion(count: count, pendingMotionType: .wordEndForward(bigWord: true), lineReader: lineReader) { line, col in
        WordMotion.nextWordEnd(in: line, from: col, bigWord: true)
      }

    // Yank / hint entry
    case "y":
      if isSelecting { return [.exitCopyMode] }
      return [.enterHintMode(.copy, .patterns), .requestHintScan]
    case "o":
      return [.enterHintMode(.open, .patterns), .requestHintScan]
    case "Y":
      if isSelecting { return [] }
      return [.enterHintMode(.copy, .lines), .requestHintScan]

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
    desiredCol = nil
    switch key {
    case "g":
      moveToTop()
      return motionActions()
    case "e":
      let count = pendingCount ?? 1
      pendingCount = nil
      return wordMotionBackward(count: count, pendingMotionType: .wordEndBackward(bigWord: false), lineReader: lineReader) { line, col in
        WordMotion.prevWordEnd(in: line, from: col, bigWord: false)
      }
    case "E":
      let count = pendingCount ?? 1
      pendingCount = nil
      return wordMotionBackward(count: count, pendingMotionType: .wordEndBackward(bigWord: true), lineReader: lineReader) { line, col in
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
    desiredCol = nil
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
    let lastContent = WordMotion.lastNonWhitespaceIndex(in: line)
    if lastContent >= 0 {
      cursorCol = min(cursorCol, lastContent)
    } else {
      cursorCol = 0  // empty/whitespace-only line
    }
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
    pendingMotionType: PendingMotion,
    lineReader: (Int) -> String?,
    motion: (String, Int) -> Int?
  ) -> [CopyModeAction] {
    for i in 0..<count {
      guard let line = lineReader(cursorRow) else { break }
      if let newCol = motion(line, cursorCol) {
        cursorCol = newCol
      } else {
        // Need to wrap to next line
        if cursorRow < rows - 1 {
          cursorRow += 1
          cursorCol = 0
          // Skip leading whitespace on the new line
          if let nextLine = lineReader(cursorRow) {
            let chars = Array(nextLine)
            var j = 0
            while j < chars.count && chars[j].isWhitespace { j += 1 }
            if j < chars.count { cursorCol = j }
          }
        } else {
          // At viewport bottom — scroll and continue
          let remaining = count - i
          pendingContinuation = ContinuationState(
            motion: pendingMotionType, remaining: remaining)
          return [.scroll(deltaRows: 1), .needsContinuation]
        }
      }
    }
    return motionActions()
  }

  /// Execute a backward word motion with cross-line wrapping
  private mutating func wordMotionBackward(
    count: Int,
    pendingMotionType: PendingMotion,
    lineReader: (Int) -> String?,
    motion: (String, Int) -> Int?
  ) -> [CopyModeAction] {
    for i in 0..<count {
      guard let line = lineReader(cursorRow) else { break }
      if let newCol = motion(line, cursorCol) {
        cursorCol = newCol
      } else {
        if cursorRow > 0 {
          cursorRow -= 1
          if let prevLine = lineReader(cursorRow) {
            cursorCol = max(0, prevLine.count - 1)
          } else {
            cursorCol = 0
          }
        } else {
          // At viewport top — scroll and continue
          let remaining = count - i
          pendingContinuation = ContinuationState(
            motion: pendingMotionType, remaining: remaining)
          return [.scroll(deltaRows: -1), .needsContinuation]
        }
      }
    }
    return motionActions()
  }

  // MARK: - Hint mode

  mutating func applyHintEntry(
    action: HintAction,
    source: HintSource,
    uppercaseAction: HintAction = .open,
    alphabet: String = "asdfghjkl"
  ) {
    subMode = .hint
    anchor = nil
    hint = HintState(
      action: action,
      source: source,
      matches: [],
      labels: [],
      uppercaseAction: uppercaseAction,
      alphabet: alphabet
    )
  }

  mutating func setHintMatches(_ matches: [HintMatch], alphabet: String) {
    guard subMode == .hint else { return }
    hint?.matches = matches
    hint?.labels = HintLabels.generate(count: matches.count, alphabet: alphabet)
    hint?.typedPrefix = ""
  }

  private mutating func handleHintKey(key: Character) -> [CopyModeAction] {
    guard var h = hint else { return [] }

    let lower = Character(key.lowercased())
    if !lower.isLetter { return exitHintCleanly() }

    if h.typedPrefix.isEmpty {
      if let idx = h.labels.firstIndex(where: { $0 == String(lower) }) {
        return executeHint(at: idx, typedUppercase: key.isUppercase)
      }
      let hasPrefix = h.labels.contains(where: { $0.count == 2 && $0.first == lower })
      if hasPrefix {
        h.typedPrefix = String(lower)
        hint = h
        return [.hintInput(key)]
      }
      return exitHintCleanly()
    } else {
      let target = h.typedPrefix + String(lower)
      if let idx = h.labels.firstIndex(where: { $0 == target }) {
        return executeHint(at: idx, typedUppercase: key.isUppercase)
      }
      return exitHintCleanly()
    }
  }

  private mutating func executeHint(at index: Int, typedUppercase: Bool) -> [CopyModeAction] {
    guard let h = hint, index < h.matches.count else { return exitHintCleanly() }
    let match = h.matches[index]

    // Action swap is driven by the *last* typed character's case.
    // For 2-char labels the second char carries the signal.
    // lowercase → h.action (default from entry key); uppercase → h.uppercaseAction (from config)
    let action: HintAction = typedUppercase ? h.uppercaseAction : h.action

    subMode = .normal
    hint = nil

    let emitted: CopyModeAction
    switch action {
    case .copy: emitted = .copyText(match.text)
    case .open: emitted = .openItem(match.text)
    }
    return [emitted, .exitHintMode, .exitCopyMode]
  }

  private mutating func exitHintCleanly() -> [CopyModeAction] {
    subMode = .normal
    hint = nil
    return [.exitHintMode, .enterSubMode(.normal)]
  }

  // MARK: - Continuation

  mutating func continuePendingMotion(
    lineReader: (Int) -> String?
  ) -> [CopyModeAction] {
    guard let continuation = pendingContinuation else { return [] }
    pendingContinuation = nil

    // Position cursor appropriately for the continued motion
    switch continuation.motion {
    case .wordForward, .wordEndForward:
      cursorCol = 0
      // Skip to first non-whitespace
      if let line = lineReader(cursorRow) {
        let chars = Array(line)
        var i = 0
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        if i < chars.count { cursorCol = i }
      }
    case .wordBackward, .wordEndBackward:
      if let line = lineReader(cursorRow) {
        cursorCol = max(0, line.count - 1)
      } else {
        cursorCol = 0
      }
    case .lineDown, .lineUp:
      clampCursorToLineContent(lineReader: lineReader)
      return motionActions()
    }

    // If remaining count > 1, continue the motion
    if continuation.remaining > 1 {
      let motionFn: (String, Int) -> Int?
      let isForward: Bool

      switch continuation.motion {
      case .wordForward(let bigWord):
        motionFn = { line, col in WordMotion.nextWordStart(in: line, from: col, bigWord: bigWord) }
        isForward = true
      case .wordBackward(let bigWord):
        motionFn = { line, col in WordMotion.prevWordStart(in: line, from: col, bigWord: bigWord) }
        isForward = false
      case .wordEndForward(let bigWord):
        motionFn = { line, col in WordMotion.nextWordEnd(in: line, from: col, bigWord: bigWord) }
        isForward = true
      case .wordEndBackward(let bigWord):
        motionFn = { line, col in WordMotion.prevWordEnd(in: line, from: col, bigWord: bigWord) }
        isForward = false
      case .lineDown, .lineUp:
        return motionActions()  // already handled above
      }

      if isForward {
        return wordMotion(count: continuation.remaining - 1, pendingMotionType: continuation.motion, lineReader: lineReader, motion: motionFn)
      } else {
        return wordMotionBackward(count: continuation.remaining - 1, pendingMotionType: continuation.motion, lineReader: lineReader, motion: motionFn)
      }
    }

    clampCursorToLineContent(lineReader: lineReader)
    return motionActions()
  }
}
