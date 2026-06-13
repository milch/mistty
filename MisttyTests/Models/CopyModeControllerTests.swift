import GhosttyKit
import XCTest

@testable import Mistty

/// Fake terminal surface for driving `CopyModeController` without a live
/// libghostty surface. `rows` is the content grid; `readText`/`readRow`
/// slice it; binding actions and pin are recorded.
@MainActor
private final class FakeTerminalContent: TerminalContentReading {
  var rows: [String] = []
  var scrollbarState = ScrollbarState()
  var cursor: (row: Int, col: Int)?
  var grid: (rows: Int, cols: Int)?
  private(set) var bindingActions: [String] = []
  private(set) var pinned = false

  func readRow(_ row: Int, pointTag: ghostty_point_tag_e) -> String? {
    guard row >= 0, row < rows.count else { return nil }
    return rows[row]
  }

  func readText(
    startRow: Int, startCol: Int, endRow: Int, endCol: Int,
    rectangle: Bool, pointTag: ghostty_point_tag_e
  ) -> String? {
    guard startRow >= 0, endRow < rows.count, startRow <= endRow else { return nil }
    if startRow == endRow {
      let chars = Array(rows[startRow])
      let s = min(startCol, chars.count), e = min(endCol + 1, chars.count)
      return s < e ? String(chars[s..<e]) : ""
    }
    var out: [String] = []
    for r in startRow...endRow {
      let chars = Array(rows[r])
      if r == startRow {
        out.append(String(chars[min(startCol, chars.count)...]))
      } else if r == endRow {
        out.append(String(chars[..<min(endCol + 1, chars.count)]))
      } else {
        out.append(rows[r])
      }
    }
    return out.joined(separator: "\n")
  }

  func viewportGridSize() -> (rows: Int, cols: Int)? { grid }
  func cursorPosition() -> (row: Int, col: Int)? { cursor }
  func runBindingAction(_ action: String) { bindingActions.append(action) }
  func pinViewport() { pinned = true }
}

@MainActor
final class CopyModeControllerTests: XCTestCase {
  private let controller = CopyModeController()

  // MARK: - makeInitialState

  func test_makeInitialState_liveEdge_usesCursorPosition() {
    let fake = FakeTerminalContent()
    fake.grid = (rows: 10, cols: 40)
    fake.cursor = (row: 3, col: 5)
    fake.scrollbarState = ScrollbarState(total: 10, offset: 0, len: 10)  // maxOffset 0

    let state = controller.makeInitialState(reader: fake)

    XCTAssertEqual(state.rows, 10)
    XCTAssertEqual(state.cols, 40)
    XCTAssertEqual(state.cursorRow, 3)
    XCTAssertEqual(state.cursorCol, 5)
    XCTAssertTrue(fake.pinned, "entering copy mode must pin the viewport")
  }

  func test_makeInitialState_inScrollback_anchorsMidViewport() {
    let fake = FakeTerminalContent()
    fake.grid = (rows: 10, cols: 40)
    fake.cursor = (row: 9, col: 5)
    // total 100, len 10 → maxOffset 90; offset 0 < 90 ⇒ user is in scrollback.
    fake.scrollbarState = ScrollbarState(total: 100, offset: 0, len: 10)

    let state = controller.makeInitialState(reader: fake)

    XCTAssertEqual(state.cursorRow, 5, "scrollback entry anchors the cursor mid-viewport")
    XCTAssertEqual(state.cursorCol, 0)
  }

  // MARK: - scrollViewport

  func test_scrollViewport_clampsAtTop_andReturnsActualDelta() {
    let fake = FakeTerminalContent()
    fake.scrollbarState = ScrollbarState(total: 100, offset: 3, len: 10)
    var state = CopyModeState(rows: 10, cols: 40, cursorRow: 0, cursorCol: 0)

    let applied = controller.scrollViewport(&state, delta: -10, reader: fake)

    XCTAssertEqual(applied, -3, "scroll past the top clamps to the actual delta")
    XCTAssertEqual(fake.scrollbarState.offset, 0)
    XCTAssertEqual(fake.bindingActions, ["scroll_page_lines:-10"])
  }

  func test_scrollViewport_clampsAtBottom() {
    let fake = FakeTerminalContent()
    fake.scrollbarState = ScrollbarState(total: 100, offset: 88, len: 10)  // maxOffset 90
    var state = CopyModeState(rows: 10, cols: 40, cursorRow: 0, cursorCol: 0)

    let applied = controller.scrollViewport(&state, delta: 10, reader: fake)

    XCTAssertEqual(applied, 2)
    XCTAssertEqual(fake.scrollbarState.offset, 90)
  }

  func test_scrollViewport_adjustsAnchorByActualDelta() {
    let fake = FakeTerminalContent()
    fake.scrollbarState = ScrollbarState(total: 100, offset: 50, len: 10)
    var state = CopyModeState(rows: 10, cols: 40, cursorRow: 0, cursorCol: 0)
    state.anchor = (row: 20, col: 3)

    _ = controller.scrollViewport(&state, delta: 5, reader: fake)

    // anchor row shifts by -actualDelta (5): 20 → 15; col unchanged.
    XCTAssertEqual(state.anchor?.row, 15)
    XCTAssertEqual(state.anchor?.col, 3)
  }

  // MARK: - runSearch

  func test_runSearch_forward_landsOnNextMatch_withIndexAndTotal() {
    let fake = FakeTerminalContent()
    fake.grid = (rows: 5, cols: 40)
    fake.scrollbarState = ScrollbarState(total: 5, offset: 0, len: 5)
    fake.rows = ["foo", "bar foo", "xxx", "foo end", "zzz"]
    var state = CopyModeState(rows: 5, cols: 40, cursorRow: 0, cursorCol: 0)
    state.searchQuery = "foo"

    controller.runSearch(&state, direction: .forward, reader: fake)

    // Matches at (0,0), (1,4), (3,0). Forward from (0,0) skips the at-cursor
    // match and lands on (1,4).
    XCTAssertEqual(state.cursorRow, 1)
    XCTAssertEqual(state.cursorCol, 4)
    XCTAssertEqual(state.searchMatchTotal, 3)
    XCTAssertEqual(state.searchMatchIndex, 2)
  }

  func test_runSearch_reverse_wrapsToLastMatch() {
    let fake = FakeTerminalContent()
    fake.grid = (rows: 5, cols: 40)
    fake.scrollbarState = ScrollbarState(total: 5, offset: 0, len: 5)
    fake.rows = ["foo", "bar foo", "xxx", "foo end", "zzz"]
    var state = CopyModeState(rows: 5, cols: 40, cursorRow: 0, cursorCol: 0)
    state.searchQuery = "foo"

    controller.runSearch(&state, direction: .reverse, reader: fake)

    // Reverse from (0,0): no match strictly before → wrap to last (3,0).
    XCTAssertEqual(state.cursorRow, 3)
    XCTAssertEqual(state.cursorCol, 0)
    XCTAssertEqual(state.searchMatchIndex, 3)
  }

  // MARK: - yankText

  func test_yankText_visualLine_returnsFullLines() {
    let fake = FakeTerminalContent()
    fake.grid = (rows: 24, cols: 11)
    fake.rows = ["hello world", "foo bar", "baz"]
    var state = CopyModeState(rows: 24, cols: 11, cursorRow: 1, cursorCol: 0)
    state.subMode = .visualLine
    state.anchor = (row: 0, col: 0)

    XCTAssertEqual(controller.yankText(state, reader: fake), "hello world\nfoo bar")
  }

  func test_yankText_visualBlock_returnsColumnSlices() {
    let fake = FakeTerminalContent()
    fake.grid = (rows: 24, cols: 6)
    fake.rows = ["abcdef", "ghijkl"]
    var state = CopyModeState(rows: 24, cols: 6, cursorRow: 1, cursorCol: 3)
    state.subMode = .visualBlock
    state.anchor = (row: 0, col: 1)

    // Columns 1...3 of each row: "bcd" / "hij".
    XCTAssertEqual(controller.yankText(state, reader: fake), "bcd\nhij")
  }

  func test_yankText_noSelection_returnsNil() {
    let fake = FakeTerminalContent()
    fake.grid = (rows: 24, cols: 40)
    let state = CopyModeState(rows: 24, cols: 40, cursorRow: 0, cursorCol: 0)
    XCTAssertNil(controller.yankText(state, reader: fake))
  }
}
