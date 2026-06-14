import XCTest

@testable import Mistty

final class ClipboardPermissionTests: XCTestCase {
  func test_global_usedWhenNoOverrides() {
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .allow, processRule: nil, sessionOverride: nil), .allow)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .prompt, processRule: nil, sessionOverride: nil), .prompt)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .deny, processRule: nil, sessionOverride: nil), .deny)
  }

  func test_processRule_beatsGlobal() {
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .deny, processRule: .allow, sessionOverride: nil), .allow)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .allow, processRule: .deny, sessionOverride: nil), .deny)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .allow, processRule: .prompt, sessionOverride: nil),
      .prompt)
  }

  func test_sessionOverride_beatsEverything() {
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .deny, processRule: .deny, sessionOverride: .allow),
      .allow)
    XCTAssertEqual(
      ClipboardPermission.resolve(global: .allow, processRule: .allow, sessionOverride: .deny),
      .deny)
  }
}
