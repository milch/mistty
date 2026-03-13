import XCTest

@testable import Mistty

@MainActor
final class SessionStoreTests: XCTestCase {
  var store: SessionStore!

  override func setUp() async throws {
    await MainActor.run {
      store = SessionStore()
    }
  }

  func test_startsEmpty() {
    XCTAssertTrue(store.sessions.isEmpty)
  }

  func test_createSession() {
    let session = store.createSession(name: "myproject", directory: URL(fileURLWithPath: "/tmp"))
    XCTAssertEqual(store.sessions.count, 1)
    XCTAssertEqual(session.name, "myproject")
    XCTAssertEqual(session.tabs.count, 1)
    XCTAssertEqual(session.tabs[0].panes.count, 1)
  }

  func test_createSessionBecomesActive() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    XCTAssertEqual(store.activeSession?.id, session.id)
  }

  func test_closeSession() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    store.closeSession(session)
    XCTAssertTrue(store.sessions.isEmpty)
    XCTAssertNil(store.activeSession)
  }

  func test_addTabToSession() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    session.addTab()
    XCTAssertEqual(session.tabs.count, 2)
  }

  func test_closeTab() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    session.addTab()
    let firstTab = session.tabs[0]
    session.closeTab(firstTab)
    XCTAssertEqual(session.tabs.count, 1)
  }

  func test_splitPaneHorizontal() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    XCTAssertEqual(tab.panes.count, 2)
  }

  func test_splitPaneVertical() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .vertical)
    XCTAssertEqual(tab.panes.count, 2)
  }

  func test_tabBellFlag() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertFalse(tab.hasBell)
    tab.hasBell = true
    XCTAssertTrue(tab.hasBell)
  }

  func test_tabCustomTitle() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertEqual(tab.displayTitle, "Shell")
    tab.customTitle = "My Tab"
    XCTAssertEqual(tab.displayTitle, "My Tab")
  }

  func test_windowModeToggle() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertFalse(tab.isWindowModeActive)
    tab.isWindowModeActive = true
    XCTAssertTrue(tab.isWindowModeActive)
  }

  func test_zoomedPaneToggle() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertNil(tab.zoomedPane)
    tab.zoomedPane = tab.panes[0]
    XCTAssertNotNil(tab.zoomedPane)
  }

  func test_createSessionWithExec() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"), exec: "nvim")
    XCTAssertEqual(session.tabs.first?.panes.first?.command, "nvim")
  }

  func test_createSessionWithoutExec() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    XCTAssertNil(session.tabs.first?.panes.first?.command)
  }

  func test_addTabWithExec() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    session.addTab(exec: "top")
    XCTAssertEqual(session.tabs.last?.panes.first?.command, "top")
  }

  func test_idsAreSequential() {
    let s1 = store.createSession(name: "a", directory: URL(fileURLWithPath: "/tmp"))
    let s2 = store.createSession(name: "b", directory: URL(fileURLWithPath: "/tmp"))
    XCTAssertEqual(s1.id, 1)
    XCTAssertEqual(s2.id, 2)
    XCTAssertEqual(s1.tabs[0].id, 1)
    XCTAssertEqual(s2.tabs[0].id, 2)
    XCTAssertEqual(s1.tabs[0].panes[0].id, 1)
    XCTAssertEqual(s2.tabs[0].panes[0].id, 2)
  }
}
