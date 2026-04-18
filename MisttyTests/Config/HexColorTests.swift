import XCTest

@testable import Mistty

final class HexColorTests: XCTestCase {
  func test_isValid_sixDigitHex() {
    XCTAssertTrue(HexColor.isValid("#3a3a3a"))
    XCTAssertTrue(HexColor.isValid("3a3a3a"))
    XCTAssertTrue(HexColor.isValid("#FFFFFF"))
  }

  func test_isValid_eightDigitHex() {
    XCTAssertTrue(HexColor.isValid("#3a3a3aff"))
    XCTAssertTrue(HexColor.isValid("3a3a3a80"))
  }

  func test_isValid_rejectsMalformed() {
    XCTAssertFalse(HexColor.isValid(""))
    XCTAssertFalse(HexColor.isValid("#"))
    XCTAssertFalse(HexColor.isValid("#xyz"))
    XCTAssertFalse(HexColor.isValid("#12345"))     // 5 digits
    XCTAssertFalse(HexColor.isValid("#1234567"))   // 7 digits
    XCTAssertFalse(HexColor.isValid("#123456789")) // 9 digits
    XCTAssertFalse(HexColor.isValid("red"))
  }

  func test_parse_returnsColorForValidHex() {
    XCTAssertNotNil(HexColor.parse("#3a3a3a"))
    XCTAssertNotNil(HexColor.parse("3a3a3aff"))
  }

  func test_parse_returnsNilForInvalid() {
    XCTAssertNil(HexColor.parse(""))
    XCTAssertNil(HexColor.parse("#gg0000"))
  }
}
