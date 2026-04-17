import XCTest

@testable import Mistty

@MainActor
final class MisttySessionSidebarLabelTests: XCTestCase {

  private func makeSession(
    name: String = "test",
    customName: String? = nil,
    directory: URL = URL(fileURLWithPath: "/Users/me/Developer/proj"),
    sshCommand: String? = nil
  ) -> MisttySession {
    let store = SessionStore()
    let s = store.createSession(
      name: name, directory: directory, customName: customName)
    s.sshCommand = sshCommand
    return s
  }

  func test_customNameWins() {
    let s = makeSession(customName: "my-project")
    XCTAssertEqual(s.sidebarLabel, "my-project")
  }

  func test_sshHostOverridesCWD() {
    let s = makeSession(sshCommand: "ssh manu@dev.example.com")
    XCTAssertEqual(s.sidebarLabel, "dev.example.com")
  }

  func test_customNameBeatsSSHHost() {
    let s = makeSession(
      customName: "staging",
      sshCommand: "ssh manu@dev.example.com"
    )
    XCTAssertEqual(s.sidebarLabel, "staging")
  }

  func test_activePaneCWDBasename() {
    let dir = URL(fileURLWithPath: "/Users/me/Developer/proj")
    let s = makeSession(directory: dir)
    XCTAssertEqual(s.sidebarLabel, "proj")
  }

  func test_fallsBackToSessionDirectoryBasename() {
    let dir = URL(fileURLWithPath: "/Users/me/other")
    let s = makeSession(directory: dir)
    s.activeTab?.activePane?.directory = nil
    XCTAssertEqual(s.sidebarLabel, "other")
  }
}
