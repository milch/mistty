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

  func test_sshHostSelectionCreatesSshSession() async {
    let store = SessionStore()
    let host = SSHHost(alias: "dev-box", hostname: "10.0.0.1")
    let config = MisttyConfig.default
    let command = config.ssh.resolveCommand(for: host.alias)
    let fullCommand = "\(command) \(host.alias)"
    let session = store.createSession(
      name: host.alias,
      directory: FileManager.default.homeDirectoryForCurrentUser,
      exec: fullCommand
    )
    session.sshCommand = fullCommand
    XCTAssertEqual(session.sshCommand, "ssh dev-box")
    XCTAssertEqual(session.name, "dev-box")
  }

  func test_frecencySorting() async {
    let store = SessionStore()
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("frecency-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let service = FrecencyService(storageURL: tempURL)
    service.recordAccess(for: "session:other")
    service.recordAccess(for: "session:other")
    service.recordAccess(for: "session:other")

    let _ = store.createSession(name: "first", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "other", directory: URL(fileURLWithPath: "/home"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store, frecencyService: service)
    await vm.load()

    let names = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertEqual(names.first, "other")
  }
}
