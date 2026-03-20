import XCTest

@testable import Mistty

final class CopyModeStateTests: XCTestCase {

  private func makeState(
    rows: Int = 24, cols: Int = 80, cursorRow: Int? = nil, cursorCol: Int? = nil
  ) -> CopyModeState {
    CopyModeState(rows: rows, cols: cols, cursorRow: cursorRow, cursorCol: cursorCol)
  }

  private let emptyLineReader: (Int) -> String? = { _ in nil }

  // MARK: - Initial state

  func test_initialState_cursorAtBottom() {
    let state = makeState()
    XCTAssertEqual(state.cursorRow, 23)
    XCTAssertEqual(state.cursorCol, 0)
    XCTAssertEqual(state.subMode, .normal)
  }

  // MARK: - Basic navigation

  func test_hjkl_movement() {
    var state = makeState(cursorRow: 10, cursorCol: 10)
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorRow, 11)

    _ = state.handleKey(key: "k", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorRow, 10)

    _ = state.handleKey(key: "l", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorCol, 11)

    _ = state.handleKey(key: "h", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorCol, 10)
  }

  func test_movement_clampsToEdges() {
    var state = makeState(cursorRow: 0, cursorCol: 0)
    _ = state.handleKey(key: "k", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorRow, 0)

    _ = state.handleKey(key: "h", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorCol, 0)
  }

  func test_lineStartEnd() {
    var state = makeState(cursorCol: 40)
    _ = state.handleKey(key: "0", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorCol, 0)

    _ = state.handleKey(key: "$", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorCol, 79)
  }

  func test_gGoesToTop_GGoesToBottom() {
    var state = makeState(cursorRow: 10)
    _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorRow, 0)
    XCTAssertEqual(state.cursorCol, 0)

    _ = state.handleKey(key: "G", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorRow, 23)
    XCTAssertEqual(state.cursorCol, 0)
  }

  // MARK: - Escape behavior (tmux-style)

  func test_escape_inNormal_exitsCopyMode() {
    var state = makeState()
    let actions = state.handleKey(
      key: "\u{1b}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.exitCopyMode))
  }

  func test_escape_inVisual_returnsToNormal() {
    var state = makeState()
    _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .visual)

    let actions = state.handleKey(
      key: "\u{1b}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.enterSubMode(.normal)))
    XCTAssertEqual(state.subMode, .normal)
    XCTAssertNil(state.anchor)
  }

  func test_escape_inVisualLine_returnsToNormal() {
    var state = makeState()
    _ = state.handleKey(key: "V", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .visualLine)

    let actions = state.handleKey(
      key: "\u{1b}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.enterSubMode(.normal)))
    XCTAssertEqual(state.subMode, .normal)
  }

  func test_escape_inVisualBlock_returnsToNormal() {
    var state = makeState()
    _ = state.handleKey(key: "v", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .visualBlock)

    let actions = state.handleKey(
      key: "\u{1b}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.enterSubMode(.normal)))
    XCTAssertEqual(state.subMode, .normal)
  }

  func test_escape_inSearch_returnsToNormal() {
    var state = makeState()
    _ = state.handleKey(key: "/", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .search)

    let actions = state.handleKey(
      key: "\u{1b}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.cancelSearch))
    XCTAssertTrue(actions.contains(.enterSubMode(.normal)))
  }

  // MARK: - Visual mode

  func test_v_entersVisual_setsAnchor() {
    var state = makeState(cursorRow: 5, cursorCol: 10)
    _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .visual)
    XCTAssertEqual(state.anchor?.row, 5)
    XCTAssertEqual(state.anchor?.col, 10)
  }

  func test_v_inVisual_returnsToNormal() {
    var state = makeState()
    _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .normal)
    XCTAssertNil(state.anchor)
  }

  // MARK: - Search

  func test_search_startAndCancel() {
    var state = makeState()
    let actions = state.handleKey(key: "/", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.startSearch))
    XCTAssertEqual(state.subMode, .search)
    XCTAssertEqual(state.searchQuery, "")
  }

  // MARK: - Word motions

  func test_w_movesToNextWord() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 6)
  }

  func test_W_movesToNextWORD() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "foo.bar baz" }
    _ = state.handleKey(key: "W", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 8)
  }

  func test_b_movesToPrevWord() {
    var state = makeState(cursorCol: 6)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "b", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 0)
  }

  func test_e_movesToWordEnd() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "e", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 4)
  }

  func test_ge_movesToPrevWordEnd() {
    var state = makeState(cursorCol: 6)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "e", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 4)
  }

  func test_w_crossLine() {
    var state = makeState(rows: 24, cols: 80, cursorRow: 5, cursorCol: 3)
    let reader: (Int) -> String? = { row in
      row == 5 ? "hello" : "world foo"
    }
    _ = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorRow, 6)
    XCTAssertEqual(state.cursorCol, 0)
  }

  // MARK: - y without selection is no-op

  func test_y_withoutSelection_isNoOp() {
    var state = makeState()
    let actions = state.handleKey(key: "y", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.isEmpty)
  }

  // MARK: - Cursor clamping to line content

  func test_dollarSign_clampsToEndOfContent() {
    var state = makeState(cursorCol: 0)
    // Line has content up to col 10, rest is whitespace padding
    let reader: (Int) -> String? = { _ in "hello world                " }
    _ = state.handleKey(key: "$", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 10)  // 'd' in "world", not col 79
  }

  func test_l_clampsToEndOfContent() {
    var state = makeState(cursorCol: 9)
    let reader: (Int) -> String? = { _ in "hello world                " }
    _ = state.handleKey(key: "l", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 10)
    // pressing l again should not move past content end
    _ = state.handleKey(key: "l", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 10)
  }

  func test_cursorClamped_emptyLine() {
    var state = makeState(cursorCol: 10)
    let reader: (Int) -> String? = { _ in "          " }  // whitespace only
    _ = state.handleKey(key: "l", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 0)
  }

  // MARK: - Find char crash fix (cursor beyond line content)

  func test_F_withCursorBeyondLineLength_noCrash() {
    var state = makeState(cursorCol: 50)
    // Line is only 11 chars but cursor is at col 50 (can happen before clamping kicks in)
    let reader: (Int) -> String? = { _ in "hello world" }
    // This should not crash — just no match found
    let actions = state.handleKey(key: "F", keyCode: 0, modifiers: [], lineReader: reader)
    _ = state.handleKey(key: "x", keyCode: 0, modifiers: [], lineReader: reader)
    // cursor gets clamped to content end
    XCTAssertEqual(state.cursorCol, 10)
  }
}
