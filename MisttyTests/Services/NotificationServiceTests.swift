import XCTest

@testable import Mistty

final class NotificationServiceTests: XCTestCase {
  func test_resolveTitle_usesRawTitleWhenPresent() {
    let result = resolveNotificationTitle(
      rawTitle: "Build finished", processTitle: "zsh", sessionLabel: "myproj")
    XCTAssertEqual(result, "Build finished")
  }

  func test_resolveTitle_fallsBackToProcessTitle() {
    let result = resolveNotificationTitle(
      rawTitle: "", processTitle: "nvim", sessionLabel: "myproj")
    XCTAssertEqual(result, "nvim")
  }

  func test_resolveTitle_fallsBackToSessionLabel() {
    let result = resolveNotificationTitle(
      rawTitle: "", processTitle: nil, sessionLabel: "myproj")
    XCTAssertEqual(result, "myproj")
  }

  func test_resolveTitle_fallsBackToMisttyWhenAllEmpty() {
    let result = resolveNotificationTitle(
      rawTitle: "", processTitle: nil, sessionLabel: "")
    XCTAssertEqual(result, "Mistty")
  }

  func test_resolveTitle_treatsWhitespaceOnlyAsEmpty() {
    let result = resolveNotificationTitle(
      rawTitle: "   ", processTitle: "  ", sessionLabel: "myproj")
    XCTAssertEqual(result, "myproj")
  }
}
