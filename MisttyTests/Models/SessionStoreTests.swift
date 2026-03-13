import XCTest
@testable import Mistty

@MainActor
final class SessionStoreTests: XCTestCase {
    var store: SessionStore!

    override func setUp() {
        store = SessionStore()
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
}
