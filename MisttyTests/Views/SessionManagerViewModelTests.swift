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

  func test_newSessionItem_plainText_properties() {
    let item = SessionManagerItem.newSession(
      query: "proj",
      directory: URL(fileURLWithPath: "/tmp/current"),
      createDirectory: false,
      sshCommand: nil
    )
    XCTAssertEqual(item.id, "new-session")
    XCTAssertEqual(item.displayName, "New session: proj")
    XCTAssertTrue(item.subtitle!.contains("/tmp/current"))
  }

  func test_newSessionItem_createDirectory_properties() {
    let item = SessionManagerItem.newSession(
      query: "~/Developer/newproj",
      directory: URL(fileURLWithPath: "/Users/test/Developer/newproj"),
      createDirectory: true,
      sshCommand: nil
    )
    XCTAssertTrue(item.displayName.contains("create directory"))
  }

  func test_newSessionItem_ssh_properties() {
    let item = SessionManagerItem.newSession(
      query: "ssh myhost",
      directory: FileManager.default.homeDirectoryForCurrentUser,
      createDirectory: false,
      sshCommand: "ssh myhost"
    )
    XCTAssertEqual(item.displayName, "New SSH session: myhost")
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

  func test_fuzzyFilter_subsequence() async {
    let store = SessionStore()
    let _ = store.createSession(name: "my-project", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("mprj")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertTrue(sessionNames.contains("my-project"))
  }

  func test_fuzzyFilter_multiToken_AND() async {
    let store = SessionStore()
    let _ = store.createSession(name: "work-bazel", directory: URL(fileURLWithPath: "/tmp/workspace"))
    let _ = store.createSession(name: "work-other", directory: URL(fileURLWithPath: "/tmp/other"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("work bazel")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertTrue(sessionNames.contains("work-bazel"))
    XCTAssertFalse(sessionNames.contains("work-other"))
  }

  func test_fuzzyFilter_matchQualityPrimary_frecencyTiebreak() async {
    let store = SessionStore()
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("frecency-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let service = FrecencyService(storageURL: tempURL)
    service.recordAccess(for: "session:dev-tools")
    service.recordAccess(for: "session:dev-tools")

    let _ = store.createSession(name: "dev", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "dev-tools", directory: URL(fileURLWithPath: "/home"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store, frecencyService: service)
    await vm.load()
    vm.updateQuery("dev")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertEqual(sessionNames.first, "dev")
  }

  func test_fuzzyFilter_storesMatchResults() async {
    let store = SessionStore()
    let _ = store.createSession(name: "my-project", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("proj")

    let matchedItem = vm.filteredItems.first { item in
      if case .runningSession = item { return true }
      return false
    }
    if let item = matchedItem {
      XCTAssertNotNil(vm.matchResults[item.id])
    }
  }

  func test_fuzzyFilter_emptyQuery_showsAll() async {
    let store = SessionStore()
    let _ = store.createSession(name: "alpha", directory: URL(fileURLWithPath: "/tmp"))
    let _ = store.createSession(name: "beta", directory: URL(fileURLWithPath: "/home"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertTrue(sessionNames.contains("alpha"))
    XCTAssertTrue(sessionNames.contains("beta"))
    XCTAssertEqual(sessionNames.count, 2)
    XCTAssertTrue(vm.matchResults.isEmpty)
  }

  func test_fuzzyFilter_whitespaceOnly_treatedAsEmpty() async {
    let store = SessionStore()
    let _ = store.createSession(name: "alpha", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("   ")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertEqual(sessionNames.count, 1)
    XCTAssertTrue(sessionNames.contains("alpha"))
  }
}
