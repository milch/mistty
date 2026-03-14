import XCTest

@testable import Mistty

@MainActor
final class SessionManagerViewModelTests: XCTestCase {
  func test_hideCurrentSession() async {
    let store = SessionStore()
    let s1 = store.createSession(name: "current", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "other", directory: URL(fileURLWithPath: "/home"))
    store.activeSession = s1

    let vm = SessionManagerViewModel(store: store)
    await vm.load()

    let sessionItems = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertFalse(sessionItems.contains("current"))
    XCTAssertTrue(sessionItems.contains("other"))
  }
}
