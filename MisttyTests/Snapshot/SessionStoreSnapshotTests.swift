import XCTest
@testable import Mistty
@testable import MisttyShared

@MainActor
final class SessionStoreSnapshotTests: XCTestCase {
  private var store: SessionStore!

  override func setUp() async throws {
    await MainActor.run {
      store = SessionStore()
    }
  }

  func test_takeSnapshot_emptyStoreProducesEmptySessions() {
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.version, WorkspaceSnapshot.currentVersion)
    XCTAssertTrue(snapshot.sessions.isEmpty)
    XCTAssertNil(snapshot.activeSessionID)
  }

  func test_takeSnapshot_capturesSingleSessionWithOnePane() {
    let session = store.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.sessions.count, 1)
    XCTAssertEqual(snapshot.activeSessionID, session.id)
    XCTAssertEqual(snapshot.sessions[0].tabs.count, 1)
    guard case .leaf(let pane) = snapshot.sessions[0].tabs[0].layout else {
      return XCTFail("expected single leaf")
    }
    XCTAssertEqual(pane.id, session.tabs[0].panes[0].id)
  }

  func test_takeSnapshot_capturesSplitLayout() {
    let session = store.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    let snapshot = store.takeSnapshot()
    guard case .split(let dir, _, _, _) = snapshot.sessions[0].tabs[0].layout else {
      return XCTFail("expected split root")
    }
    XCTAssertEqual(dir, .horizontal)
  }

  func test_takeSnapshot_preservesCustomNames() {
    let session = store.createSession(
      name: "work", directory: URL(fileURLWithPath: "/tmp"), customName: "Work")
    session.tabs[0].customTitle = "repl"
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.sessions[0].customName, "Work")
    XCTAssertEqual(snapshot.sessions[0].tabs[0].customTitle, "repl")
  }

  func test_takeSnapshot_preservesSSHCommand() {
    let session = store.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    session.sshCommand = "ssh user@host"
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.sessions[0].sshCommand, "ssh user@host")
  }

  func test_takeSnapshot_preservesActiveIDs() {
    let s = store.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    s.addTab()
    let secondTab = s.tabs[1]
    s.activeTab = secondTab
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.activeSessionID, s.id)
    XCTAssertEqual(snapshot.sessions[0].activeTabID, secondTab.id)
    XCTAssertEqual(snapshot.sessions[0].tabs[1].activePaneID, secondTab.panes[0].id)
  }
}
