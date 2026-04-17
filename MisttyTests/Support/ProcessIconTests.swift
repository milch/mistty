import XCTest

@testable import Mistty

final class ProcessIconTests: XCTestCase {
  func test_nilInputReturnsFallback() {
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: nil), ProcessIcon.fallbackGlyph)
  }

  func test_emptyStringReturnsFallback() {
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: ""), ProcessIcon.fallbackGlyph)
  }

  func test_knownProcess_nvim() {
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: "nvim"), ProcessIcon.nvimGlyph)
  }

  func test_knownProcessWithArgs() {
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: "nvim PLAN.md"), ProcessIcon.nvimGlyph)
  }

  func test_knownProcessCaseInsensitive() {
    XCTAssertEqual(ProcessIcon.glyph(forProcessTitle: "NVIM"), ProcessIcon.nvimGlyph)
  }

  func test_unknownProcessReturnsFallback() {
    XCTAssertEqual(
      ProcessIcon.glyph(forProcessTitle: "some-unknown-binary"),
      ProcessIcon.fallbackGlyph)
  }
}
