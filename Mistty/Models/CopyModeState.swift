import Foundation

struct CopyModeState {
  let rows: Int
  let cols: Int
  var cursorRow: Int
  var cursorCol: Int = 0
  var isSelecting = false
  var selectionStart: (row: Int, col: Int)?
  var searchQuery: String = ""
  var isSearching = false

  init(rows: Int, cols: Int) {
    self.rows = rows
    self.cols = cols
    self.cursorRow = rows - 1
  }

  mutating func moveUp() { cursorRow = max(0, cursorRow - 1) }
  mutating func moveDown() { cursorRow = min(rows - 1, cursorRow + 1) }
  mutating func moveLeft() { cursorCol = max(0, cursorCol - 1) }
  mutating func moveRight() { cursorCol = min(cols - 1, cursorCol + 1) }
  mutating func moveToLineStart() { cursorCol = 0 }
  mutating func moveToLineEnd() { cursorCol = cols - 1 }
  mutating func moveWordForward() {
    cursorCol = min(cols - 1, cursorCol + 5)
  }
  mutating func moveWordBackward() {
    cursorCol = max(0, cursorCol - 5)
  }
  mutating func moveToTop() {
    cursorRow = 0
    cursorCol = 0
  }
  mutating func moveToBottom() {
    cursorRow = rows - 1
    cursorCol = 0
  }

  mutating func toggleSelection() {
    isSelecting.toggle()
    if isSelecting {
      selectionStart = (cursorRow, cursorCol)
    } else {
      selectionStart = nil
    }
  }

  var selectionRange: (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
    guard isSelecting, let start = selectionStart else { return nil }
    return (start, (cursorRow, cursorCol))
  }
}
