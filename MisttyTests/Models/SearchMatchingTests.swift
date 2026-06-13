import XCTest

@testable import Mistty

/// Pure-logic tests for copy-mode search-match arithmetic. The FFI scan
/// that produces the `[SearchMatch]` array lives in ContentView (untestable
/// without a live surface); this covers the jump-target and index math
/// that used to be interleaved with the scan loops.
final class SearchMatchingTests: XCTestCase {
  // Sorted by (row, col), as the scanner produces them.
  private let matches = [
    SearchMatch(row: 2, col: 4),
    SearchMatch(row: 2, col: 9),
    SearchMatch(row: 5, col: 0),
    SearchMatch(row: 9, col: 7),
  ]

  func test_nextMatch_forward_findsFirstAfterCursor() {
    let m = SearchMatching.nextMatch(after: 2, col: 4, in: matches, forward: true)
    XCTAssertEqual(m, SearchMatch(row: 2, col: 9))
  }

  func test_nextMatch_forward_skipsMatchAtCursor() {
    // A match exactly at the cursor must not be returned (n moves on).
    let m = SearchMatching.nextMatch(after: 5, col: 0, in: matches, forward: true)
    XCTAssertEqual(m, SearchMatch(row: 9, col: 7))
  }

  func test_nextMatch_forward_wrapsPastEnd() {
    let m = SearchMatching.nextMatch(after: 9, col: 7, in: matches, forward: true)
    XCTAssertEqual(m, SearchMatch(row: 2, col: 4))
  }

  func test_nextMatch_reverse_findsLastBeforeCursor() {
    let m = SearchMatching.nextMatch(after: 5, col: 0, in: matches, forward: false)
    XCTAssertEqual(m, SearchMatch(row: 2, col: 9))
  }

  func test_nextMatch_reverse_wrapsPastStart() {
    let m = SearchMatching.nextMatch(after: 2, col: 4, in: matches, forward: false)
    XCTAssertEqual(m, SearchMatch(row: 9, col: 7))
  }

  func test_nextMatch_emptyMatches_returnsNil() {
    XCTAssertNil(SearchMatching.nextMatch(after: 0, col: 0, in: [], forward: true))
    XCTAssertNil(SearchMatching.nextMatch(after: 0, col: 0, in: [], forward: false))
  }

  func test_index_isOneBasedPositionInSortedOrder() {
    XCTAssertEqual(SearchMatching.index(of: SearchMatch(row: 2, col: 4), in: matches), 1)
    XCTAssertEqual(SearchMatching.index(of: SearchMatch(row: 9, col: 7), in: matches), 4)
    XCTAssertNil(SearchMatching.index(of: SearchMatch(row: 0, col: 0), in: matches))
  }
}
