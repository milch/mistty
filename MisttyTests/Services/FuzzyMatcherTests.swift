import XCTest

@testable import Mistty

final class FuzzyMatcherTests: XCTestCase {
  // MARK: - Strict ordered match

  func test_exactMatch() {
    let result = FuzzyMatcher.match(query: "foo", target: "foo")
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.matchedIndices, [0, 1, 2])
  }

  func test_prefixMatch() {
    let result = FuzzyMatcher.match(query: "foo", target: "foobar")
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.matchedIndices, [0, 1, 2])
  }

  func test_subsequenceMatch() {
    let result = FuzzyMatcher.match(query: "fb", target: "foobar")
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.matchedIndices.count, 2)
    XCTAssertTrue(result!.matchedIndices.contains(0)) // f
    XCTAssertTrue(result!.matchedIndices.contains(3)) // b
  }

  func test_caseInsensitive() {
    let result = FuzzyMatcher.match(query: "FOO", target: "foobar")
    XCTAssertNotNil(result)
  }

  func test_noMatch() {
    let result = FuzzyMatcher.match(query: "xyz", target: "foobar")
    XCTAssertNil(result)
  }

  func test_emptyQuery() {
    let result = FuzzyMatcher.match(query: "", target: "foobar")
    XCTAssertNil(result)
  }

  func test_queryLongerThanTarget() {
    let result = FuzzyMatcher.match(query: "foobarextralongquery", target: "foo")
    XCTAssertNil(result)
  }
}
