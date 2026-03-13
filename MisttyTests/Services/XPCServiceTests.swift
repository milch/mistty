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
}
