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
    let sessionDir = URL(fileURLWithPath: "/Users/me/Developer/proj")
    let paneDir = URL(fileURLWithPath: "/tmp/deep/nested/runtime")
    let s = makeSession(directory: sessionDir)
    s.activeTab?.activePane?.directory = paneDir
    XCTAssertEqual(s.sidebarLabel, "runtime")
  }

  func test_fallsBackToSessionDirectoryBasename() {
    let dir = URL(fileURLWithPath: "/Users/me/other")
    let s = makeSession(directory: dir)
    s.activeTab?.activePane?.directory = nil
    XCTAssertEqual(s.sidebarLabel, "other")
  }

  func test_sshCommandWithNoHostFallsThroughToCWD() {
    let s = makeSession(
      directory: URL(fileURLWithPath: "/Users/me/Developer/proj"),
      sshCommand: "ssh -p 22"
    )
    XCTAssertEqual(s.sidebarLabel, "proj")
  }

  func test_emptyCustomNameFallsThroughToCWD() {
    let s = makeSession(
      customName: "",
      directory: URL(fileURLWithPath: "/Users/me/Developer/proj")
    )
    XCTAssertEqual(s.sidebarLabel, "proj")
  }
}
