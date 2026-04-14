import XCTest
@testable import Mistty

final class HintDetectorTests: XCTestCase {

  private func scan(_ lines: [String]) -> [HintMatch] {
    HintDetector.detect(lines: lines, source: .patterns)
  }

  func test_url_detected() {
    let m = scan(["visit https://example.com/x today"])
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].kind, .url)
    XCTAssertEqual(m[0].text, "https://example.com/x")
  }

  func test_url_trailing_punctuation_stripped() {
    let m = scan(["see https://example.com."])
    XCTAssertEqual(m[0].text, "https://example.com")
  }

  func test_uuid_detected() {
    let m = scan(["id 550e8400-e29b-41d4-a716-446655440000 ok"])
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].kind, .uuid)
  }

  func test_path_detected() {
    let m = scan(["open /usr/local/bin/foo now"])
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].kind, .path)
    XCTAssertEqual(m[0].text, "/usr/local/bin/foo")
  }

  func test_hash_detected() {
    let m = scan(["sha abc1234 ok"])
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].kind, .hash)
    XCTAssertEqual(m[0].text, "abc1234")
  }

  func test_longest_match_wins_between_peers() {
    // A path that contains a hash-looking substring — only the path wins.
    let m = scan(["/a/abcdef0 file"])
    let kinds = Set(m.map(\.kind))
    XCTAssertTrue(kinds.contains(.path))
    XCTAssertFalse(kinds.contains(.hash))
  }

  func test_container_codeSpan_emitsBothOuterAndInner() {
    let m = scan(["run `abcdef1234567` quick"])
    XCTAssertEqual(m.count, 2)
    XCTAssertTrue(m.contains(where: { $0.kind == .codeSpan }))
    XCTAssertTrue(m.contains(where: { $0.kind == .hash }))
  }

  func test_container_quoted_emitsBothOuterAndInner() {
    let m = scan(["echo \"/tmp/x.log\""])
    XCTAssertEqual(m.count, 2)
    XCTAssertTrue(m.contains(where: { $0.kind == .quoted }))
    XCTAssertTrue(m.contains(where: { $0.kind == .path }))
  }

  func test_envVar_vs_number() {
    let m = scan(["PORT 8080"])
    let kinds = Set(m.map(\.kind))
    XCTAssertTrue(kinds.contains(.envVar))
    XCTAssertTrue(kinds.contains(.number))
  }

  func test_line_source_skipsEmptyLines() {
    let lines = ["hello", "   ", "", "world"]
    let m = HintDetector.detect(lines: lines, source: .lines)
    XCTAssertEqual(m.count, 2)
    // Bottom-to-top ordering: "world" (row 3) before "hello" (row 0)
    XCTAssertEqual(m.map(\.text), ["world", "hello"])
    XCTAssertEqual(m[0].kind, .line)
  }

  func test_ordering_bottomToTop_leftToRight() {
    let lines = ["a http://one.com b", "c http://two.com d http://three.com"]
    let matches = scan(lines)
    // Expect two.com first, three.com second (bottom row, L→R), then one.com
    XCTAssertEqual(matches.map(\.text), [
      "http://two.com", "http://three.com", "http://one.com"
    ])
  }
}
