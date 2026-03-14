import AppKit
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
    tab.windowModeState = .normal
    XCTAssertTrue(tab.isWindowModeActive)
  }

  func test_windowModeState() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    XCTAssertEqual(tab.windowModeState, .inactive)
    tab.windowModeState = .normal
    XCTAssertTrue(tab.isWindowModeActive)
    tab.windowModeState = .joinPick
    XCTAssertTrue(tab.isWindowModeActive)
    tab.windowModeState = .inactive
    XCTAssertFalse(tab.isWindowModeActive)
  }

  func test_addExistingPane() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let tab1 = session.tabs[0]
    tab1.splitActivePane(direction: .horizontal)
    XCTAssertEqual(tab1.panes.count, 2)

    session.addTab()
    let tab2 = session.tabs[1]
    XCTAssertEqual(tab2.panes.count, 1)

    let paneToMove = tab1.panes[0]
    tab1.closePane(paneToMove)
    tab2.addExistingPane(paneToMove, direction: .horizontal)

    XCTAssertEqual(tab1.panes.count, 1)
    XCTAssertEqual(tab2.panes.count, 2)
    XCTAssertTrue(tab2.panes.contains(where: { $0.id == paneToMove.id }))
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

  // MARK: - Window Registry

  func test_registerWindow() {
    let window = NSWindow()
    let id = store.registerWindow(window)
    XCTAssertEqual(id, 1)
    XCTAssertEqual(store.trackedWindows.count, 1)
  }

  func test_unregisterWindow() {
    let window = NSWindow()
    let _ = store.registerWindow(window)
    store.unregisterWindow(window)
    XCTAssertTrue(store.trackedWindows.isEmpty)
  }

  func test_windowIdsAreStable() {
    let w1 = NSWindow()
    let w2 = NSWindow()
    let id1 = store.registerWindow(w1)
    let id2 = store.registerWindow(w2)
    store.unregisterWindow(w1)
    XCTAssertEqual(store.trackedWindows.first?.id, id2)
    XCTAssertEqual(id1, 1)
    XCTAssertEqual(id2, 2)
  }

  func test_registerSameWindowTwice() {
    let window = NSWindow()
    let id1 = store.registerWindow(window)
    let id2 = store.registerWindow(window)
    XCTAssertEqual(id1, id2)
    XCTAssertEqual(store.trackedWindows.count, 1)
  }

  func test_trackedWindowById() {
    let window = NSWindow()
    let id = store.registerWindow(window)
    let tracked = store.trackedWindow(byId: id)
    XCTAssertNotNil(tracked)
    XCTAssertEqual(tracked?.id, id)
    XCTAssertTrue(tracked?.window === window)
    XCTAssertNil(store.trackedWindow(byId: 999))
  }

  // MARK: - Tab/Session Cycling

  func test_nextTab_wrapsAround() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    session.addTab()
    session.addTab()
    // Active is last tab (index 2)
    session.nextTab()
    XCTAssertEqual(session.activeTab?.id, session.tabs[0].id)
  }

  func test_prevTab_wrapsAround() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    session.addTab()
    session.addTab()
    session.activeTab = session.tabs[0]
    session.prevTab()
    XCTAssertEqual(session.activeTab?.id, session.tabs[2].id)
  }

  func test_nextSession_wrapsAround() {
    let _ = store.createSession(name: "a", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "b", directory: URL(fileURLWithPath: "/tmp"))
    let s3 = store.createSession(name: "c", directory: URL(fileURLWithPath: "/tmp"))
    XCTAssertEqual(store.activeSession?.id, s3.id)
    store.nextSession()
    XCTAssertEqual(store.activeSession?.name, "a")
  }

  func test_prevSession_wrapsAround() {
    let s1 = store.createSession(name: "a", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "b", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "c", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = s1
    store.prevSession()
    XCTAssertEqual(store.activeSession?.name, "c")
  }

  func test_focusTabByIndex_boundsCheck() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    session.addTab()
    session.activeTab = session.tabs[0]
    let index = 5
    if index < session.tabs.count {
      session.activeTab = session.tabs[index]
    }
    XCTAssertEqual(session.activeTab?.id, session.tabs[0].id)
  }

  func test_paneProcessTitle() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let pane = session.tabs[0].panes[0]
    XCTAssertNil(pane.processTitle)
    pane.processTitle = "nvim"
    XCTAssertEqual(pane.processTitle, "nvim")
  }

  func test_isRunningNeovim() {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    let pane = session.tabs[0].panes[0]

    pane.processTitle = "zsh"
    XCTAssertFalse(pane.isRunningNeovim)

    pane.processTitle = "nvim"
    XCTAssertTrue(pane.isRunningNeovim)

    pane.processTitle = "nvim ."
    XCTAssertTrue(pane.isRunningNeovim)

    pane.processTitle = "vim"
    XCTAssertTrue(pane.isRunningNeovim)

    pane.processTitle = "vimtutor"
    XCTAssertFalse(pane.isRunningNeovim)

    pane.processTitle = nil
    XCTAssertFalse(pane.isRunningNeovim)
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
