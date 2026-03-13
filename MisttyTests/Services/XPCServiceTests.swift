import XCTest

@testable import Mistty
@testable import MisttyShared

@MainActor
final class XPCServiceTests: XCTestCase {
    var store: SessionStore!
    var service: MisttyXPCService!

    override func setUp() async throws {
        await MainActor.run {
            store = SessionStore()
            service = MisttyXPCService(store: store)
        }
    }

    func testCreateSession() async throws {
        let expectation = XCTestExpectation(description: "create session")
        service.createSession(name: "test", directory: "/tmp", exec: nil) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let response = try! JSONDecoder().decode(SessionResponse.self, from: data!)
            XCTAssertEqual(response.name, "test")
            XCTAssertEqual(response.directory, "/tmp")
            XCTAssertEqual(response.tabCount, 1)
            XCTAssertFalse(response.tabIds.isEmpty)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        // Verify store was updated
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testCreateSessionDefaultDirectory() async throws {
        let expectation = XCTestExpectation(description: "create session default dir")
        service.createSession(name: "home", directory: nil, exec: nil) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let response = try! JSONDecoder().decode(SessionResponse.self, from: data!)
            XCTAssertEqual(response.name, "home")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testListSessions() async throws {
        store.createSession(name: "alpha", directory: URL(fileURLWithPath: "/tmp"))
        store.createSession(name: "beta", directory: URL(fileURLWithPath: "/tmp"))

        let expectation = XCTestExpectation(description: "list sessions")
        service.listSessions { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let responses = try! JSONDecoder().decode([SessionResponse].self, from: data!)
            XCTAssertEqual(responses.count, 2)
            XCTAssertEqual(responses[0].name, "alpha")
            XCTAssertEqual(responses[1].name, "beta")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testListSessionsEmpty() async throws {
        let expectation = XCTestExpectation(description: "list sessions empty")
        service.listSessions { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let responses = try! JSONDecoder().decode([SessionResponse].self, from: data!)
            XCTAssertTrue(responses.isEmpty)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testGetSession() async throws {
        let session = store.createSession(name: "myproject", directory: URL(fileURLWithPath: "/tmp"))

        let expectation = XCTestExpectation(description: "get session")
        service.getSession(id: session.id) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let response = try! JSONDecoder().decode(SessionResponse.self, from: data!)
            XCTAssertEqual(response.id, session.id)
            XCTAssertEqual(response.name, "myproject")
            XCTAssertEqual(response.directory, "/tmp")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testGetSessionNotFound() async throws {
        let expectation = XCTestExpectation(description: "get session not found")
        service.getSession(id: 999) { data, error in
            XCTAssertNil(data)
            XCTAssertNotNil(error)
            let nsError = error! as NSError
            XCTAssertEqual(nsError.domain, MisttyXPC.errorDomain)
            XCTAssertEqual(nsError.code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testCloseSession() async throws {
        let session = store.createSession(name: "doomed", directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(store.sessions.count, 1)

        let expectation = XCTestExpectation(description: "close session")
        service.closeSession(id: session.id) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testCloseSessionNotFound() async throws {
        let expectation = XCTestExpectation(description: "close session not found")
        service.closeSession(id: 999) { data, error in
            XCTAssertNil(data)
            XCTAssertNotNil(error)
            let nsError = error! as NSError
            XCTAssertEqual(nsError.code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - Tab Tests

    func testCreateTab() async throws {
        let session = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(session.tabs.count, 1)

        let expectation = XCTestExpectation(description: "create tab")
        service.createTab(sessionId: session.id, name: "build", exec: nil) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let response = try! JSONDecoder().decode(TabResponse.self, from: data!)
            XCTAssertEqual(response.title, "build")
            XCTAssertEqual(response.paneCount, 1)
            XCTAssertFalse(response.paneIds.isEmpty)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(session.tabs.count, 2)
    }

    func testListTabs() async throws {
        let session = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))
        session.addTab()

        let expectation = XCTestExpectation(description: "list tabs")
        service.listTabs(sessionId: session.id) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let responses = try! JSONDecoder().decode([TabResponse].self, from: data!)
            XCTAssertEqual(responses.count, 2)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testCloseTab() async throws {
        let session = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))
        session.addTab()
        XCTAssertEqual(session.tabs.count, 2)
        let tabId = session.tabs[0].id

        let expectation = XCTestExpectation(description: "close tab")
        service.closeTab(id: tabId) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(session.tabs.count, 1)
    }

    func testRenameTab() async throws {
        let session = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))
        let tab = session.tabs[0]

        let expectation = XCTestExpectation(description: "rename tab")
        service.renameTab(id: tab.id, name: "logs") { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let response = try! JSONDecoder().decode(TabResponse.self, from: data!)
            XCTAssertEqual(response.title, "logs")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(tab.customTitle, "logs")
    }

    // MARK: - Pane Tests

    func testListPanes() async throws {
        let session = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))
        let tab = session.tabs[0]

        let expectation = XCTestExpectation(description: "list panes")
        service.listPanes(tabId: tab.id) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let responses = try! JSONDecoder().decode([PaneResponse].self, from: data!)
            XCTAssertEqual(responses.count, 1)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testActivePane() async throws {
        let session = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))
        let pane = session.tabs[0].panes[0]

        let expectation = XCTestExpectation(description: "active pane")
        service.activePane { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let response = try! JSONDecoder().decode(PaneResponse.self, from: data!)
            XCTAssertEqual(response.id, pane.id)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testClosePane() async throws {
        let session = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))
        let tab = session.tabs[0]
        // Split to get two panes so we can close one
        tab.splitActivePane(direction: .vertical)
        XCTAssertEqual(tab.panes.count, 2)
        let paneToClose = tab.panes[0]

        let expectation = XCTestExpectation(description: "close pane")
        service.closePane(id: paneToClose.id) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(tab.panes.count, 1)
    }

    func testGetPaneNotFound() async throws {
        let expectation = XCTestExpectation(description: "get pane not found")
        service.getPane(id: 999) { data, error in
            XCTAssertNil(data)
            XCTAssertNotNil(error)
            let nsError = error! as NSError
            XCTAssertEqual(nsError.code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - SendKeys / RunCommand Tests

    func testSendKeysResolvesPane() async throws {
        let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
        let paneId = session.activeTab!.activePane!.id

        let expectation = XCTestExpectation(description: "send keys")
        service.sendKeys(paneId: paneId, keys: "hello") { data, error in
            // Pane found but surface is nil in test → operationFailed
            if let error = error as? NSError {
                XCTAssertEqual(error.code, MisttyXPC.ErrorCode.operationFailed.rawValue)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testSendKeysPaneNotFound() async throws {
        let expectation = XCTestExpectation(description: "send keys not found")
        service.sendKeys(paneId: 999, keys: "hello") { data, error in
            XCTAssertNotNil(error)
            XCTAssertEqual((error! as NSError).code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testSendKeysActivePane() async throws {
        let _ = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))

        let expectation = XCTestExpectation(description: "send keys active")
        service.sendKeys(paneId: 0, keys: "hello") { data, error in
            // Resolves active pane, surface nil → operationFailed
            if let error = error as? NSError {
                XCTAssertEqual(error.code, MisttyXPC.ErrorCode.operationFailed.rawValue)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testRunCommandDelegatesToSendKeys() async throws {
        let expectation = XCTestExpectation(description: "run command not found")
        service.runCommand(paneId: 999, command: "ls") { data, error in
            XCTAssertNotNil(error)
            XCTAssertEqual((error! as NSError).code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - GetText Tests

    func testGetTextResolvesPane() async throws {
        let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
        let paneId = session.activeTab!.activePane!.id

        let expectation = XCTestExpectation(description: "get text")
        service.getText(paneId: paneId) { data, error in
            if let error = error as? NSError {
                XCTAssertEqual(error.code, MisttyXPC.ErrorCode.operationFailed.rawValue)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testGetTextPaneNotFound() async throws {
        let expectation = XCTestExpectation(description: "get text not found")
        service.getText(paneId: 999) { data, error in
            XCTAssertNotNil(error)
            XCTAssertEqual((error! as NSError).code, MisttyXPC.ErrorCode.entityNotFound.rawValue)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testGetTextActivePane() async throws {
        let _ = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))

        let expectation = XCTestExpectation(description: "get text active")
        service.getText(paneId: 0) { data, error in
            // Resolves active pane, surface nil → operationFailed
            if let error = error as? NSError {
                XCTAssertEqual(error.code, MisttyXPC.ErrorCode.operationFailed.rawValue)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testFocusPane() async throws {
        let session = store.createSession(name: "proj", directory: URL(fileURLWithPath: "/tmp"))
        let tab = session.tabs[0]
        tab.splitActivePane(direction: .vertical)
        let firstPane = tab.panes[0]
        // Active pane should be the second (newly split) pane
        XCTAssertNotEqual(tab.activePane?.id, firstPane.id)

        let expectation = XCTestExpectation(description: "focus pane")
        service.focusPane(id: firstPane.id) { data, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            let response = try! JSONDecoder().decode(PaneResponse.self, from: data!)
            XCTAssertEqual(response.id, firstPane.id)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(tab.activePane?.id, firstPane.id)
        XCTAssertEqual(store.activeSession?.id, session.id)
        XCTAssertEqual(session.activeTab?.id, tab.id)
    }
}
