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

  // MARK: - Scoring heuristics

  func test_prefixMatchScoresHigher() {
    let prefix = FuzzyMatcher.match(query: "pro", target: "project")!
    let middle = FuzzyMatcher.match(query: "pro", target: "my-project")!
    XCTAssertGreaterThan(prefix.score, middle.score)
  }

  func test_wordBoundaryScoresHigher() {
    let boundary = FuzzyMatcher.match(query: "pro", target: "my-project")!
    let scattered = FuzzyMatcher.match(query: "pro", target: "xpxrxoxx")!
    XCTAssertGreaterThan(boundary.score, scattered.score)
  }

  func test_consecutiveMatchScoresHigher() {
    let consecutive = FuzzyMatcher.match(query: "abc", target: "xabcx")!
    let scattered = FuzzyMatcher.match(query: "abc", target: "xaxbxcx")!
    XCTAssertGreaterThan(consecutive.score, scattered.score)
  }

  func test_shorterTargetScoresHigher() {
    let short = FuzzyMatcher.match(query: "foo", target: "foobar")!
    let long = FuzzyMatcher.match(query: "foo", target: "foo-and-a-very-long-suffix")!
    XCTAssertGreaterThan(short.score, long.score)
  }

  func test_pathBoundaryMatching() {
    let result = FuzzyMatcher.match(query: "proj", target: "~/Developer/project")!
    // "~/Developer/" is 13 chars, so 'p' in 'project' is at index 13
    XCTAssertTrue(result.matchedIndices.contains(13)) // 'p' after last '/'
  }
}
