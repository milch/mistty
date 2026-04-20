import XCTest

@testable import Mistty

final class TerminalTitleTests: XCTestCase {
  func test_passesThroughPlainTitle() {
    XCTAssertEqual(TerminalTitle.sanitized("nvim — mistty"), "nvim — mistty")
  }

  func test_trimsWhitespace() {
    XCTAssertEqual(TerminalTitle.sanitized("  zsh  "), "zsh")
  }

  func test_nilForEmpty() {
    XCTAssertNil(TerminalTitle.sanitized(""))
  }

  func test_nilForWhitespaceOnly() {
    XCTAssertNil(TerminalTitle.sanitized("   \n\t "))
  }

  func test_rejectsBareExit() {
    XCTAssertNil(TerminalTitle.sanitized("exit"))
  }

  func test_rejectsExitWithArgs() {
    XCTAssertNil(TerminalTitle.sanitized("exit 0"))
    XCTAssertNil(TerminalTitle.sanitized("exit $PATH"))
    XCTAssertNil(TerminalTitle.sanitized("exit && echo done"))
  }

  func test_allowsCommandsThatMerelyContainExit() {
    // "exit" must be followed by end-of-string or whitespace — words that
    // start with "exit" (exitcode, exiting) stay.
    XCTAssertEqual(TerminalTitle.sanitized("exitcode"), "exitcode")
    XCTAssertEqual(TerminalTitle.sanitized("exiting now"), "exiting now")
  }

  func test_allowsDollarPrefixedTitles() {
    // The $PATH part of "exit $PATH" was incidental — we only care about
    // the exit leader. Dollar-prefixed text elsewhere must pass through.
    XCTAssertEqual(TerminalTitle.sanitized("$USER@$HOST"), "$USER@$HOST")
    XCTAssertEqual(TerminalTitle.sanitized("${PWD}"), "${PWD}")
    XCTAssertEqual(TerminalTitle.sanitized("Price: $5"), "Price: $5")
  }
}
