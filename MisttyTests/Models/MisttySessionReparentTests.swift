import XCTest

@testable import Mistty

@MainActor
final class MisttySessionReparentTests: XCTestCase {

  private func makeSession(
    name: String = "proj",
    customName: String? = nil,
    directory: URL = URL(fileURLWithPath: "/Users/me/Developer/proj")
  ) -> MisttySession {
    let store = WindowsStore()
    let state = store.createWindow()
    return state.createSession(name: name, directory: directory, customName: customName)
  }

  func test_setDirectory_updatesDirectory() {
    let s = makeSession()
    let newDir = URL(fileURLWithPath: "/Users/me/Developer/other")
    s.setDirectory(newDir)
    XCTAssertEqual(s.directory, newDir)
  }

  func test_setDirectory_resyncsNameWhenItTrackedOldBasename() {
    let s = makeSession(
      name: "proj",
      directory: URL(fileURLWithPath: "/Users/me/Developer/proj"))
    s.setDirectory(URL(fileURLWithPath: "/Users/me/Developer/other"))
    XCTAssertEqual(s.name, "other")
  }

  func test_setDirectory_leavesCustomNameAlone() {
    let s = makeSession(
      customName: "my-staging",
      directory: URL(fileURLWithPath: "/Users/me/Developer/proj"))
    s.setDirectory(URL(fileURLWithPath: "/Users/me/Developer/other"))
    XCTAssertEqual(s.customName, "my-staging")
    XCTAssertEqual(s.sidebarLabel, "my-staging")
  }

  func test_setDirectory_leavesNameAloneIfItDoesNotMatchOldBasename() {
    let s = makeSession(
      name: "Default",
      directory: URL(fileURLWithPath: "/Users/me/Developer/proj"))
    s.setDirectory(URL(fileURLWithPath: "/Users/me/Developer/other"))
    XCTAssertEqual(s.name, "Default", "manually-set name should survive reparent")
  }

  func test_setDirectory_newTabsInheritNewDirectory() {
    let s = makeSession(directory: URL(fileURLWithPath: "/Users/me/Developer/proj"))
    let newDir = URL(fileURLWithPath: "/Users/me/Developer/other")
    s.setDirectory(newDir)
    s.addTab()
    XCTAssertEqual(s.tabs.last?.directory, newDir)
  }

  func test_setDirectory_doesNotMoveExistingPanes() {
    let oldDir = URL(fileURLWithPath: "/Users/me/Developer/proj")
    let s = makeSession(directory: oldDir)
    let originalPane = s.activeTab?.activePane
    XCTAssertEqual(originalPane?.directory, oldDir)
    s.setDirectory(URL(fileURLWithPath: "/Users/me/Developer/other"))
    XCTAssertEqual(originalPane?.directory, oldDir,
                   "existing panes keep their initial spawn dir; only new tabs pick up the new dir")
  }
}
