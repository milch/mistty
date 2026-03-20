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
    XCTAssertEqual(state.subMode, .searchForward)

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
    XCTAssertEqual(state.subMode, .searchForward)
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

  // MARK: - Desired column (j/k remember column across short lines)

  func test_jk_restoresDesiredCol() {
    // Line 5 has 20 chars, line 6 has 5 chars, line 7 has 20 chars
    var state = makeState(cursorRow: 5, cursorCol: 15)
    let reader: (Int) -> String? = { row in
      switch row {
      case 5: return "01234567890123456789"
      case 6: return "abcde"
      case 7: return "01234567890123456789"
      default: return ""
      }
    }
    // Move down to short line — cursor clamps to col 4
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorRow, 6)
    XCTAssertEqual(state.cursorCol, 4)  // clamped to "abcde" end

    // Move down again to long line — cursor restores to col 15
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorRow, 7)
    XCTAssertEqual(state.cursorCol, 15)  // restored
  }

  func test_dollarThenJ_goesToEndOfEachLine() {
    var state = makeState(cursorRow: 5, cursorCol: 0)
    let reader: (Int) -> String? = { row in
      switch row {
      case 5: return "short"
      case 6: return "a longer line here"
      default: return ""
      }
    }
    // $ goes to end of "short"
    _ = state.handleKey(key: "$", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 4)

    // j should go to end of next line ($ sets desiredCol to Int.max)
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorRow, 6)
    XCTAssertEqual(state.cursorCol, 17)  // end of "a longer line here"
  }

  func test_horizontalMotion_resetsDesiredCol() {
    var state = makeState(cursorRow: 5, cursorCol: 15)
    let reader: (Int) -> String? = { row in
      switch row {
      case 5: return "01234567890123456789"
      case 6: return "abcde"
      case 7: return "01234567890123456789"
      default: return ""
      }
    }
    // j to short line
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 4)

    // h resets desiredCol
    _ = state.handleKey(key: "h", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorCol, 3)

    // j again — should use cursorCol 3, NOT restore to 15
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorRow, 7)
    XCTAssertEqual(state.cursorCol, 3)
  }

  func test_5j_desiredCol_acrossVaryingLines() {
    var state = makeState(cursorRow: 0, cursorCol: 15)
    let reader: (Int) -> String? = { row in
      switch row {
      case 0: return "01234567890123456789"  // 20 chars
      case 1: return "abc"                    // 3 chars
      case 2: return "abcde"                  // 5 chars
      case 3: return "ab"                     // 2 chars
      case 4: return "abcdefghij"             // 10 chars
      case 5: return "01234567890123456789"  // 20 chars
      default: return ""
      }
    }
    // 5j should land on row 5 with col 15 restored (skips intermediate short lines)
    _ = state.handleKey(key: "5", keyCode: 0, modifiers: [], lineReader: reader)
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorRow, 5)
    XCTAssertEqual(state.cursorCol, 15)
  }

  func test_desiredCol_acrossEmptyLine() {
    var state = makeState(cursorRow: 5, cursorCol: 10)
    let reader: (Int) -> String? = { row in
      switch row {
      case 5: return "hello world!!"          // 13 chars
      case 6: return "               "        // whitespace-only
      case 7: return "another long line here"  // 22 chars
      default: return ""
      }
    }
    // j to empty line — cursor forced to 0, desiredCol preserved
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorRow, 6)
    XCTAssertEqual(state.cursorCol, 0)

    // j again — restored to col 10
    _ = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: reader)
    XCTAssertEqual(state.cursorRow, 7)
    XCTAssertEqual(state.cursorCol, 10)
  }

  // MARK: - Phase 2: Paging

  func test_ctrlD_returnsScrollDown() {
    var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
    let actions = state.handleKey(key: "d", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: 12)))
  }

  func test_ctrlU_returnsScrollUp() {
    var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
    let actions = state.handleKey(key: "u", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: -12)))
  }

  func test_ctrlF_returnsFullPageDown() {
    var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
    let actions = state.handleKey(key: "f", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: 24)))
  }

  func test_ctrlB_returnsFullPageUp() {
    var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
    let actions = state.handleKey(key: "b", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: -24)))
  }

  func test_5ctrlD_pagesDown5HalfScreens() {
    var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
    _ = state.handleKey(key: "5", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    let actions = state.handleKey(key: "d", keyCode: 0, modifiers: .control, lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: 60)))
  }

  // MARK: - Phase 2: j/k scrolling at viewport edges

  func test_j_atBottomRow_returnsScroll() {
    var state = makeState(rows: 24, cursorRow: 23, cursorCol: 0)
    let actions = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: 1)))
    XCTAssertEqual(state.cursorRow, 23)
  }

  func test_k_atTopRow_returnsScroll() {
    var state = makeState(rows: 24, cursorRow: 0, cursorCol: 0)
    let actions = state.handleKey(key: "k", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: -1)))
    XCTAssertEqual(state.cursorRow, 0)
  }

  func test_3j_atRow22_scrollsBy2() {
    var state = makeState(rows: 24, cursorRow: 22, cursorCol: 0)
    _ = state.handleKey(key: "3", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    let actions = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: 2)))
    XCTAssertEqual(state.cursorRow, 23)
  }

  func test_j_inMiddle_noScroll() {
    var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
    let actions = state.handleKey(key: "j", keyCode: 0, modifiers: [], lineReader: emptyLineReader)
    XCTAssertFalse(actions.contains(where: { if case .scroll = $0 { return true }; return false }))
    XCTAssertEqual(state.cursorRow, 11)
  }

  // MARK: - Phase 2: Search direction and continuation

  func test_searchDirection_defaultsToForward() {
    let state = makeState()
    XCTAssertEqual(state.searchDirection, .forward)
  }

  func test_pendingContinuation_defaultsToNil() {
    let state = makeState()
    XCTAssertNil(state.pendingContinuation)
  }

  // MARK: - Phase 2: Word motion at viewport edge

  func test_w_atLastRow_returnsScrollAndContinuation() {
    // "hello world" — cursor at col 6 (on "w"), w should find nothing after "world" and try next line
    // At row 23 (last), should scroll instead
    let lines = Array(repeating: "hello world", count: 24)
    let lineReader: (Int) -> String? = { row in
      row >= 0 && row < lines.count ? lines[row] : nil
    }
    var state = makeState(rows: 24, cursorRow: 23, cursorCol: 6)
    let actions = state.handleKey(key: "w", keyCode: 0, modifiers: [], lineReader: lineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: 1)))
    XCTAssertTrue(actions.contains(.needsContinuation))
    XCTAssertNotNil(state.pendingContinuation)
  }

  func test_b_atFirstRow_returnsScrollAndContinuation() {
    let lines = Array(repeating: "hello world", count: 24)
    let lineReader: (Int) -> String? = { row in
      row >= 0 && row < lines.count ? lines[row] : nil
    }
    var state = makeState(rows: 24, cursorRow: 0, cursorCol: 0)
    let actions = state.handleKey(key: "b", keyCode: 0, modifiers: [], lineReader: lineReader)
    XCTAssertTrue(actions.contains(.scroll(deltaRows: -1)))
    XCTAssertTrue(actions.contains(.needsContinuation))
  }

  func test_continuePendingMotion_completesWordForward() {
    var state = makeState(rows: 24, cursorRow: 23, cursorCol: 0)
    state.pendingContinuation = ContinuationState(
      motion: .wordForward(bigWord: false), remaining: 1)
    let newLines = Array(repeating: "foo bar baz", count: 24)
    let lineReader: (Int) -> String? = { row in
      row >= 0 && row < newLines.count ? newLines[row] : nil
    }
    let actions = state.continuePendingMotion(lineReader: lineReader)
    XCTAssertEqual(state.cursorCol, 0)  // "foo" starts at 0
    XCTAssertTrue(actions.contains(.cursorMoved))
    XCTAssertNil(state.pendingContinuation)
  }

  func test_continuePendingMotion_noPending_returnsEmpty() {
    var state = makeState(rows: 24, cursorRow: 10, cursorCol: 0)
    let actions = state.continuePendingMotion(lineReader: emptyLineReader)
    XCTAssertTrue(actions.isEmpty)
  }
}
