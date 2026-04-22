import XCTest

@testable import Mistty

@MainActor
final class PopupCommandWrapTests: XCTestCase {
  func test_simpleCommand() {
    XCTAssertEqual(MisttySession.wrapPopupCommand("btop"), "sh -c 'btop'")
  }

  func test_multiStatement() {
    XCTAssertEqual(
      MisttySession.wrapPopupCommand("echo a; echo b"),
      "sh -c 'echo a; echo b'"
    )
  }

  func test_commandWithAnd() {
    XCTAssertEqual(
      MisttySession.wrapPopupCommand("cd /tmp && nvim"),
      "sh -c 'cd /tmp && nvim'"
    )
  }

  func test_commandWithSingleQuotes() {
    // echo 'hello' → sh -c 'echo '\''hello'\'''
    XCTAssertEqual(
      MisttySession.wrapPopupCommand("echo 'hello'"),
      #"sh -c 'echo '\''hello'\'''"#
    )
  }

  func test_commandWithBackslash() {
    // Backslashes don't need special handling inside single quotes in POSIX sh.
    XCTAssertEqual(
      MisttySession.wrapPopupCommand(#"echo \n"#),
      #"sh -c 'echo \n'"#
    )
  }
}
