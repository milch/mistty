import XCTest

@testable import Mistty

@MainActor
final class ClipboardPermissionCoordinatorTests: XCTestCase {
  func test_decision_usesConfigWhenNoSessionOverride() {
    let coord = ClipboardPermissionCoordinator()
    var config = MisttyConfig()
    config.clipboardRead = .deny
    config.clipboardProcessRules = [.init(name: "nvim", mode: .allow)]

    XCTAssertEqual(coord.decision(forExecutable: "nvim", sessionID: 1, config: config), .allow)
    XCTAssertEqual(coord.decision(forExecutable: "zsh", sessionID: 1, config: config), .deny)
  }

  func test_sessionOverride_winsAndIsScopedToSession() {
    let coord = ClipboardPermissionCoordinator()
    let config = MisttyConfig()  // global .prompt
    coord.setSessionOverride(.allow, executable: "nvim", sessionID: 1)

    XCTAssertEqual(coord.decision(forExecutable: "nvim", sessionID: 1, config: config), .allow)
    // Different session → no override → falls back to global .prompt.
    XCTAssertEqual(coord.decision(forExecutable: "nvim", sessionID: 2, config: config), .prompt)
  }

  func test_clearSession_dropsOverrides() {
    let coord = ClipboardPermissionCoordinator()
    let config = MisttyConfig()
    coord.setSessionOverride(.allow, executable: "nvim", sessionID: 1)
    coord.clearSession(1)
    XCTAssertEqual(coord.decision(forExecutable: "nvim", sessionID: 1, config: config), .prompt)
  }

  func test_applyChoice_effects() {
    let coord = ClipboardPermissionCoordinator()

    // allowOnce / denyOnce: no session override, no persisted rule.
    let allowOnce = coord.applyChoice(.allowOnce, executable: "a", sessionID: 1)
    XCTAssertTrue(allowOnce.allowed)
    XCTAssertNil(allowOnce.persist)
    let denyOnce = coord.applyChoice(.denyOnce, executable: "a", sessionID: 1)
    XCTAssertFalse(denyOnce.allowed)
    XCTAssertNil(denyOnce.persist)

    // session choice sets an in-memory override, persists nothing.
    let session = coord.applyChoice(.allowSession, executable: "b", sessionID: 1)
    XCTAssertTrue(session.allowed)
    XCTAssertNil(session.persist)
    XCTAssertEqual(coord.decision(forExecutable: "b", sessionID: 1, config: MisttyConfig()), .allow)

    // always choices return a persisted rule for the caller to write.
    let allowAlways = coord.applyChoice(.allowAlways, executable: "c", sessionID: 1)
    XCTAssertTrue(allowAlways.allowed)
    XCTAssertEqual(allowAlways.persist, .init(name: "c", mode: .allow))
    let denyAlways = coord.applyChoice(.denyAlways, executable: "d", sessionID: 1)
    XCTAssertFalse(denyAlways.allowed)
    XCTAssertEqual(denyAlways.persist, .init(name: "d", mode: .deny))
  }
}
