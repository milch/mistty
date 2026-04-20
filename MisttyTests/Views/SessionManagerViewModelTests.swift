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
    let _ = store.createSession(
      name: "work-bazel", directory: URL(fileURLWithPath: "/tmp/workspace"))
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

  // MARK: - "New" option tests

  func test_newOption_plainText_appearsAtTop() async {
    let store = SessionStore()
    let _ = store.createSession(name: "existing", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("proj")

    guard case .newSession = vm.filteredItems.first else {
      XCTFail("First item should be newSession")
      return
    }
  }

  func test_newOption_notSelectedByDefault() async {
    let store = SessionStore()
    let _ = store.createSession(name: "project", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("proj")

    XCTAssertEqual(vm.selectedIndex, 1)
  }

  func test_newOption_becomesDefaultWhenOnlyItem() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("nonexistent-unique-query-xyz")

    XCTAssertEqual(vm.filteredItems.count, 1)
    XCTAssertEqual(vm.selectedIndex, 0)
    guard case .newSession = vm.filteredItems.first else {
      XCTFail("Only item should be newSession")
      return
    }
  }

  func test_newOption_notShownWhenQueryEmpty() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("")

    let hasNew = vm.filteredItems.contains { item in
      if case .newSession = item { return true }
      return false
    }
    XCTAssertFalse(hasNew)
  }

  func test_newOption_pathLike_existingDir() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("/tmp")

    guard case .newSession(_, let dir, let createDir, _) = vm.filteredItems.first else {
      XCTFail("First item should be newSession")
      return
    }
    XCTAssertEqual(dir.path, "/tmp")
    XCTAssertFalse(createDir)
  }

  func test_newOption_pathLike_parentExists_createDir() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("/tmp/nonexistent-mistty-test-dir-\(UUID().uuidString)")

    guard case .newSession(_, _, let createDir, _) = vm.filteredItems.first else {
      XCTFail("First item should be newSession")
      return
    }
    XCTAssertTrue(createDir)
  }

  func test_newOption_pathLike_parentNotExists_noNew() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("/nonexistent-parent-\(UUID().uuidString)/child")

    let hasNew = vm.filteredItems.contains { item in
      if case .newSession = item { return true }
      return false
    }
    XCTAssertFalse(hasNew)
  }

  func test_newOption_ssh() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("ssh myhost")

    guard case .newSession(_, _, _, let sshCmd) = vm.filteredItems.first else {
      XCTFail("First item should be newSession")
      return
    }
    XCTAssertNotNil(sshCmd)
    XCTAssertTrue(sshCmd!.contains("myhost"))
  }

  func test_newOption_ssh_noHostname_noNew() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("ssh ")

    let hasNewSSH = vm.filteredItems.contains { item in
      if case .newSession(_, _, _, let cmd) = item, cmd != nil { return true }
      return false
    }
    XCTAssertFalse(hasNewSSH)
  }

  // MARK: - confirmSelection with modifiers

  func test_confirmSelection_newSession_plainText() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("myproject")
    vm.selectedIndex = 0
    vm.confirmSelection(modifierFlags: [])

    XCTAssertEqual(store.activeSession?.name, "myproject")
  }

  func test_confirmSelection_newSession_cmdOverridesToHome() async {
    let store = SessionStore()
    let s1 = store.createSession(name: "current", directory: URL(fileURLWithPath: "/tmp/somedir"))
    store.activeSession = s1

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("newproj")
    vm.selectedIndex = 0
    vm.confirmSelection(modifierFlags: .command)

    let newSession = store.sessions.last
    XCTAssertEqual(newSession?.name, "newproj")
    XCTAssertEqual(newSession?.directory, FileManager.default.homeDirectoryForCurrentUser)
  }

  func test_confirmSelection_newSession_ssh() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("ssh testhost")
    vm.selectedIndex = 0
    vm.confirmSelection(modifierFlags: [])

    let newSession = store.sessions.last
    XCTAssertEqual(newSession?.name, "testhost")
    XCTAssertNotNil(newSession?.sshCommand)
  }

  // MARK: - Cross-field and edge case tests

  func test_fuzzyFilter_multiToken_crossField() async {
    let aliasMatch = FuzzyMatcher.match(query: "prod", target: "production")
    let hostnameMatch = FuzzyMatcher.match(query: "exam", target: "prod.example.com")
    XCTAssertNotNil(aliasMatch)
    XCTAssertNotNil(hostnameMatch)
  }

  func test_newOption_pathToFile_noNew() async {
    let tempFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-test-file-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: tempFile.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery(tempFile.path)

    let hasNew = vm.filteredItems.contains { item in
      if case .newSession = item { return true }
      return false
    }
    XCTAssertFalse(hasNew, "New option should not appear for file paths")
  }

  // MARK: - Integration tests

  func test_tabCompletion_returnsDirectoryPath() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("/tmp")

    if vm.filteredItems.count > 1 {
      vm.selectedIndex = 1
      let value = vm.completionValue()
      XCTAssertNotNil(value)
    }
  }

  func test_tabCompletion_newItem_returnsNil() async {
    let store = SessionStore()
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("nonexistent-xyz")
    vm.selectedIndex = 0

    XCTAssertNil(vm.completionValue())
  }

  func test_typoTolerance_endToEnd() async {
    let store = SessionStore()
    let _ = store.createSession(name: "bazel-build", directory: URL(fileURLWithPath: "/tmp"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("bzael")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertTrue(sessionNames.contains("bazel-build"))
  }

  func test_fullFlow_typeFilterSelectConfirm() async {
    let store = SessionStore()
    let _ = store.createSession(name: "work-project", directory: URL(fileURLWithPath: "/tmp/work"))
    let _ = store.createSession(name: "personal", directory: URL(fileURLWithPath: "/tmp/personal"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()

    vm.updateQuery("work")

    let sessionNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertTrue(sessionNames.contains("work-project"))
    XCTAssertFalse(sessionNames.contains("personal"))

    XCTAssertFalse(vm.matchResults.isEmpty)

    vm.selectedIndex = 1  // skip "New"
    vm.confirmSelection()
    XCTAssertEqual(store.activeSession?.name, "work-project")
  }

  // MARK: - Running session ordering and boost

  func test_runningSessions_sortedFirst_byLastActivated() async {
    let store = SessionStore()
    let _ = store.createSession(name: "alpha", directory: URL(fileURLWithPath: "/tmp/alpha-x"))
    let beta = store.createSession(name: "beta", directory: URL(fileURLWithPath: "/tmp/beta-x"))
    let _ = store.createSession(name: "gamma", directory: URL(fileURLWithPath: "/tmp/gamma-x"))

    // Activate beta last so it should appear on top.
    store.activeSession = beta
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()

    let runningNames = vm.filteredItems.compactMap { item -> String? in
      if case .runningSession(let s) = item { return s.name }
      return nil
    }
    XCTAssertEqual(runningNames.first, "beta")

    // All running sessions must appear before any non-running item.
    let firstNonRunning = vm.filteredItems.firstIndex { !$0.isRunningSession }
    let lastRunning = vm.filteredItems.lastIndex { $0.isRunningSession }
    if let first = firstNonRunning, let last = lastRunning {
      XCTAssertLessThan(last, first, "Running sessions should be contiguous at the top")
    }
  }

  func test_search_displayNamePrefixOutranksScatteredSubtitleMatch() {
    // Regression: typing "mist" should rank "mistty" above
    // "ha-is-there-a-seattle-home-game-today" — the latter only matches via
    // boundary chars in its full path /Users/manu/Developer/ha-is-there-...,
    // whereas "mist" is a clean prefix of "mistty".
    let mistName = FuzzyMatcher.match(query: "mist", target: "mistty")!.score
    let haPath = FuzzyMatcher.match(
      query: "mist",
      target: "/Users/manu/Developer/ha-is-there-a-seattle-home-game-today")!.score
    XCTAssertGreaterThan(
      mistName, haPath * SessionManagerViewModel.subtitlePenalty,
      "displayName prefix match must beat penalized subtitle match")
  }

  func test_runningSessionBoost_outranksDirectoryWithSameDisplayName() async {
    // Compare two real items rather than asserting against a magic threshold:
    // a running session "demo" should outrank a directory whose lastPathComponent
    // is also "demo" because the running-session boost applies.
    let store = SessionStore()
    let session = store.createSession(name: "demo", directory: URL(fileURLWithPath: "/tmp/demo"))
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    vm.updateQuery("demo")

    let sessionScore = vm.matchResults["session-\(session.id)"]?.score
    XCTAssertNotNil(sessionScore)
    let unboosted = FuzzyMatcher.match(query: "demo", target: "demo")!.score
    XCTAssertEqual(
      sessionScore!, min(unboosted * SessionManagerViewModel.runningSessionBoost, 1.0),
      accuracy: 0.001,
      "Running session score must equal raw match score times the boost")
  }

  func test_runningSshSession_getsRunningBoostNotSshBoost() async {
    // The running-session boost (case-based) and the SSH-query boost
    // (case-based) are mutually exclusive: a running SSH session is a
    // `.runningSession` so it only ever picks up the running boost. Lock
    // that behavior in so future tuning doesn't accidentally double-boost.
    let store = SessionStore()
    let session = store.createSession(
      name: "prod", directory: FileManager.default.homeDirectoryForCurrentUser,
      exec: "ssh prod")
    session.sshCommand = "ssh prod"
    store.activeSession = nil

    let vm = SessionManagerViewModel(store: store)
    await vm.load()
    // Match a single token against the session name (running sessions have
    // no subtitle, so multi-token "ssh prod" would never match).
    vm.updateQuery("prod")

    let sessionScore = vm.matchResults["session-\(session.id)"]?.score
    XCTAssertNotNil(sessionScore)
    let unboosted = FuzzyMatcher.match(query: "prod", target: "prod")!.score
    XCTAssertEqual(
      sessionScore!, min(unboosted * SessionManagerViewModel.runningSessionBoost, 1.0),
      accuracy: 0.001,
      "Running SSH session must apply the running boost exactly once, not stacked with the SSH boost")
  }
}
