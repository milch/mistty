import XCTest

@testable import Mistty

final class CopyModeStateTests: XCTestCase {
  func test_initialCursorPosition() {
    let state = CopyModeState(rows: 24, cols: 80)
    XCTAssertEqual(state.cursorRow, 23)  // Bottom of screen
    XCTAssertEqual(state.cursorCol, 0)
  }

  func test_moveDown() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorRow = 10
    state.moveDown()
    XCTAssertEqual(state.cursorRow, 11)
  }

  func test_moveDownClampsToBottom() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorRow = 23
    state.moveDown()
    XCTAssertEqual(state.cursorRow, 23)
  }

  func test_moveRight() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.moveRight()
    XCTAssertEqual(state.cursorCol, 1)
  }

  func test_toggleSelection() {
    var state = CopyModeState(rows: 24, cols: 80)
    XCTAssertFalse(state.isSelecting)
    state.toggleSelection()
    XCTAssertTrue(state.isSelecting)
    XCTAssertNotNil(state.selectionStart)
  }

  func test_moveWordForward() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorCol = 0
    state.moveWordForward()
    XCTAssertEqual(state.cursorCol, 5)
  }

  func test_moveWordBackward() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorCol = 10
    state.moveWordBackward()
    XCTAssertEqual(state.cursorCol, 5)
  }

  func test_moveWordForwardClampsToEnd() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorCol = 78
    state.moveWordForward()
    XCTAssertEqual(state.cursorCol, 79)
  }

  func test_moveWordBackwardClampsToStart() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorCol = 3
    state.moveWordBackward()
    XCTAssertEqual(state.cursorCol, 0)
  }

  func test_homeAndEnd() {
    var state = CopyModeState(rows: 24, cols: 80)
    state.cursorCol = 40
    state.moveToLineStart()
    XCTAssertEqual(state.cursorCol, 0)
    state.moveToLineEnd()
    XCTAssertEqual(state.cursorCol, 79)
  }
}
