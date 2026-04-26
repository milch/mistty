import XCTest

@testable import Mistty

final class CopyModeIntegrationTests: XCTestCase {

  private func makeState(
    rows: Int = 24, cols: Int = 80, cursorRow: Int? = nil, cursorCol: Int? = nil
  ) -> CopyModeState {
    CopyModeState(rows: rows, cols: cols, cursorRow: cursorRow, cursorCol: cursorCol)
  }

  private let emptyLineReader: (Int) -> String? = { _ in nil }

  // MARK: - Number prefixes

  func test_countMovement_5j() {
    var state = makeState(cursorRow: 10)
    _ = state.handleKey(key: "5", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorRow, 15)
  }

  func test_countMovement_10l() {
    var state = makeState(cursorCol: 0)
    _ = state.handleKey(key: "1", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "0", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "l", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorCol, 10)
  }

  func test_0_withoutCount_isLineStart() {
    var state = makeState(cursorCol: 40)
    _ = state.handleKey(key: "0", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorCol, 0)
  }

  func test_5G_goesToLine5() {
    var state = makeState(cursorRow: 10)
    _ = state.handleKey(key: "5", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "G", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.cursorRow, 4)  // 0-indexed
  }

  func test_3w_movesThreeWords() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "one two three four" }
    _ = state.handleKey(key: "3", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 14)  // "four"
  }

  // MARK: - f/F/t/T

  func test_f_findsCharForward() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "f", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "o", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 4)  // first 'o' in "hello"
  }

  func test_F_findsCharBackward() {
    var state = makeState(cursorCol: 10)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "F", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "l", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 9)  // 'l' in "world"
  }

  func test_t_stopsBeforeChar() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "hello world" }
    _ = state.handleKey(key: "t", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 5)  // one before 'w' at col 6
  }

  func test_semicolon_repeatsFind() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "abacada" }
    _ = state.handleKey(key: "f", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "a", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 2)  // second 'a'

    _ = state.handleKey(key: ";", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 4)  // third 'a'
  }

  func test_comma_reversesFind() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "abacada" }
    _ = state.handleKey(key: "f", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "a", keyCode: 0, modifiers: [], lineReader: reader)
    _ = state.handleKey(key: ";", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 4)

    _ = state.handleKey(key: ",", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 2)
  }

  func test_3fa_findsThirdOccurrence() {
    var state = makeState(cursorCol: 0)
    let reader: (Int) -> String? = { _ in "xaxaxax" }
    _ = state.handleKey(key: "3", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "f", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "a", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 5)  // third 'a'
  }

  // MARK: - Visual mode switching

  func test_V_entersVisualLine() {
    var state = makeState()
    _ = state.handleKey(key: "V", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .visualLine)
  }

  func test_ctrlV_entersVisualBlock() {
    var state = makeState()
    _ = state.handleKey(key: "v", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .visualBlock)
  }

  func test_v_inVisualLine_switchesToVisual() {
    var state = makeState()
    _ = state.handleKey(key: "V", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "v", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .visual)
    XCTAssertNotNil(state.anchor)
  }

  func test_V_inVisualLine_returnsToNormal() {
    var state = makeState()
    _ = state.handleKey(key: "V", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "V", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertEqual(state.subMode, .normal)
    XCTAssertNil(state.anchor)
  }

  // MARK: - g? help toggle

  func test_gQuestion_togglesHelp() {
    var state = makeState()
    _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    let actions = state.handleKey(key: "?", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(state.showingHelp)
    XCTAssertTrue(actions.contains(.showHelp))
  }

  func test_helpDismissedByAnyKey() {
    var state = makeState()
    _ = state.handleKey(key: "g", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    _ = state.handleKey(key: "?", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(state.showingHelp)

    let actions = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertFalse(state.showingHelp)
    XCTAssertTrue(actions.contains(.hideHelp))
    // cursor NOT moved — key was consumed by help dismissal
    XCTAssertEqual(state.cursorRow, 23)
  }

  // MARK: - Phase 2: Search direction

  func test_questionMark_entersReverseSearch() {
    var state = makeState(cursorRow: 10, cursorCol: 5)
    let actions = state.handleKey(key: "?", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.startSearch))
    XCTAssertEqual(state.subMode, .searchReverse)
    XCTAssertEqual(state.searchDirection, .reverse)
  }

  func test_N_returnsSearchPrev() {
    var state = makeState(cursorRow: 10, cursorCol: 5)
    state.searchQuery = "test"
    let actions = state.handleKey(key: "N", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.searchPrev))
  }

  func test_ctrlD_returnsHalfPageScroll() {
    var state = makeState(cursorRow: 10, cursorCol: 0)
    let actions = state.handleKey(key: "d", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: 12)))
  }

  func test_escape_clearsContinuation() {
    var state = makeState(cursorRow: 10, cursorCol: 0)
    state.pendingContinuation = ContinuationState(motion: .lineDown, remaining: 1)
    let actions = state.handleKey(key: "\u{1B}", keyCode: 53, modifiers: [], lineReader: emptyLineReader)
    XCTAssertNil(state.pendingContinuation)
    XCTAssertTrue(actions.contains(.exitCopyMode))
  }

  // MARK: - Visual yank normalization

  func test_visualYankNormalizes_whenCursorBeforeAnchor() {
    // (row=5, col=10) anchor; (row=2, col=3) cursor.
    let (top, bottom) = CopyModeYank.normalize(
      anchor: (row: 5, col: 10),
      cursor: (row: 2, col: 3)
    )
    XCTAssertEqual(top.row, 2)
    XCTAssertEqual(top.col, 3)
    XCTAssertEqual(bottom.row, 5)
    XCTAssertEqual(bottom.col, 10)
  }

  func test_visualYankNormalizes_whenSameRowCursorBefore() {
    let (top, bottom) = CopyModeYank.normalize(
      anchor: (row: 4, col: 20),
      cursor: (row: 4, col: 5)
    )
    XCTAssertEqual(top.col, 5)
    XCTAssertEqual(bottom.col, 20)
  }

  func test_visualYankNormalizes_whenAnchorBeforeCursor() {
    let (top, bottom) = CopyModeYank.normalize(
      anchor: (row: 1, col: 0),
      cursor: (row: 99, col: 0)
    )
    XCTAssertEqual(top.row, 1)
    XCTAssertEqual(bottom.row, 99)
    XCTAssertEqual(top.col, 0)
    XCTAssertEqual(bottom.col, 0)
  }

  func test_visualYankNormalizes_whenAnchorEqualsCursor() {
    let (top, bottom) = CopyModeYank.normalize(
      anchor: (row: 3, col: 7),
      cursor: (row: 3, col: 7)
    )
    XCTAssertEqual(top.row, 3)
    XCTAssertEqual(top.col, 7)
    XCTAssertEqual(bottom.row, 3)
    XCTAssertEqual(bottom.col, 7)
  }
}
