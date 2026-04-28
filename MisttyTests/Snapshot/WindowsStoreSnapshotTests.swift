import XCTest
@testable import Mistty
@testable import MisttyShared

@MainActor
final class WindowsStoreSnapshotTests: XCTestCase {
  private var store: WindowsStore!
  private var state: WindowState!

  override func setUp() async throws {
    await MainActor.run {
      store = WindowsStore()
      state = store.createWindow()
    }
  }

  // MARK: - takeSnapshot

  func test_takeSnapshot_emptyStoreProducesEmptySessions() {
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.version, WorkspaceSnapshot.currentVersion)
    XCTAssertEqual(snapshot.windows.count, 1)
    XCTAssertNil(snapshot.activeWindowID)
    XCTAssertTrue(snapshot.windows[0].sessions.isEmpty)
    XCTAssertNil(snapshot.windows[0].activeSessionID)
  }

  func test_takeSnapshot_capturesSingleSessionWithOnePane() {
    let session = state.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.windows.count, 1)
    XCTAssertEqual(snapshot.windows[0].activeSessionID, session.id)
    XCTAssertEqual(snapshot.windows[0].sessions[0].tabs.count, 1)
    guard case .leaf(let pane) = snapshot.windows[0].sessions[0].tabs[0].layout else {
      return XCTFail("expected single leaf")
    }
    XCTAssertEqual(pane.id, session.tabs[0].panes[0].id)
  }

  func test_takeSnapshot_capturesSplitLayout() {
    let session = state.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    let snapshot = store.takeSnapshot()
    guard case .split(let dir, _, _, _) = snapshot.windows[0].sessions[0].tabs[0].layout else {
      return XCTFail("expected split root")
    }
    XCTAssertEqual(dir, .horizontal)
  }

  func test_takeSnapshot_preservesCustomNames() {
    let session = state.createSession(
      name: "work", directory: URL(fileURLWithPath: "/tmp"), customName: "Work")
    session.tabs[0].customTitle = "repl"
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.windows[0].sessions[0].customName, "Work")
    XCTAssertEqual(snapshot.windows[0].sessions[0].tabs[0].customTitle, "repl")
  }

  func test_takeSnapshot_preservesSSHCommand() {
    let session = state.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    session.sshCommand = "ssh user@host"
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.windows[0].sessions[0].sshCommand, "ssh user@host")
  }

  func test_takeSnapshot_preservesActiveIDs() {
    let s = state.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    s.addTab()
    let secondTab = s.tabs[1]
    s.activeTab = secondTab
    let snapshot = store.takeSnapshot()
    XCTAssertEqual(snapshot.windows[0].activeSessionID, s.id)
    XCTAssertEqual(snapshot.windows[0].sessions[0].activeTabID, secondTab.id)
    XCTAssertEqual(snapshot.windows[0].sessions[0].tabs[1].activePaneID, secondTab.panes[0].id)
  }

  // MARK: - restore

  /// Helper: access the first restored window state. After restore(), states
  /// live in pendingRestoreStates until WindowRootView mounts and claims them.
  private func firstRestoredState() -> WindowState? {
    store.pendingRestoreStates.first
  }

  func test_restore_emptyWorkspaceLeavesStoreEmpty() {
    _ = state.createSession(name: "leftover", directory: URL(fileURLWithPath: "/tmp"))
    store.restore(from: WorkspaceSnapshot(version: 2, windows: [], activeWindowID: nil), config: RestoreConfig())
    XCTAssertTrue(store.windows.isEmpty)
    XCTAssertTrue(store.pendingRestoreStates.isEmpty)
  }

  func test_restore_rebuildsSingleSession() {
    let snapshot = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 1,
          sessions: [
            SessionSnapshot(
              id: 7,
              name: "work",
              customName: "Work",
              directory: URL(fileURLWithPath: "/tmp"),
              sshCommand: nil,
              lastActivatedAt: Date(),
              tabs: [
                TabSnapshot(
                  id: 3,
                  customTitle: nil,
                  directory: URL(fileURLWithPath: "/tmp"),
                  layout: .leaf(pane: PaneSnapshot(id: 42)),
                  activePaneID: 42
                ),
              ],
              activeTabID: 3
            ),
          ],
          activeSessionID: 7
        ),
      ],
      activeWindowID: 1
    )
    store.restore(from: snapshot, config: RestoreConfig())
    let restoredState = firstRestoredState()!
    XCTAssertEqual(restoredState.sessions.count, 1)
    XCTAssertEqual(restoredState.sessions[0].id, 7)
    XCTAssertEqual(restoredState.sessions[0].customName, "Work")
    XCTAssertEqual(restoredState.activeSession?.id, 7)
    XCTAssertEqual(restoredState.sessions[0].tabs[0].id, 3)
    XCTAssertEqual(restoredState.sessions[0].tabs[0].panes[0].id, 42)
  }

  func test_restore_rebuildsSplitLayout() {
    let snapshot = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 1,
          sessions: [
            SessionSnapshot(
              id: 1, name: "w",
              directory: URL(fileURLWithPath: "/tmp"),
              lastActivatedAt: Date(),
              tabs: [
                TabSnapshot(
                  id: 1,
                  layout: .split(
                    direction: .horizontal,
                    a: .leaf(pane: PaneSnapshot(id: 10)),
                    b: .leaf(pane: PaneSnapshot(id: 11)),
                    ratio: 0.3
                  ),
                  activePaneID: 11
                ),
              ],
              activeTabID: 1
            ),
          ],
          activeSessionID: 1
        ),
      ],
      activeWindowID: 1
    )
    store.restore(from: snapshot, config: RestoreConfig())
    let restoredState = firstRestoredState()!
    let tab = restoredState.sessions[0].tabs[0]
    XCTAssertEqual(tab.panes.count, 2)
    XCTAssertEqual(tab.activePane?.id, 11)
    guard case .split(let dir, _, _, let ratio) = tab.layout.root else {
      return XCTFail("expected split")
    }
    XCTAssertEqual(dir, .horizontal)
    XCTAssertEqual(ratio, 0.3, accuracy: 0.0001)
  }

  func test_restore_advancesIDCountersPastMax() {
    let snapshot = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 1,
          sessions: [
            SessionSnapshot(
              id: 50, name: "w",
              directory: URL(fileURLWithPath: "/tmp"),
              lastActivatedAt: Date(),
              tabs: [
                TabSnapshot(
                  id: 30,
                  layout: .leaf(pane: PaneSnapshot(id: 99)),
                  activePaneID: 99
                ),
              ],
              activeTabID: 30
            ),
          ],
          activeSessionID: 50
        ),
      ],
      activeWindowID: 1
    )
    store.restore(from: snapshot, config: RestoreConfig())
    // Register the pending state so it's accessible via windows
    let restoredState = firstRestoredState()!
    store.registerRestoredWindow(restoredState)
    let fresh = restoredState.createSession(name: "post", directory: URL(fileURLWithPath: "/tmp"))
    XCTAssertGreaterThan(fresh.id, 50)
    XCTAssertGreaterThan(fresh.tabs[0].id, 30)
    XCTAssertGreaterThan(fresh.tabs[0].panes[0].id, 99)
  }

  // Regression for the "session label drifts into cd'd-into subfolder"
  // bug. Before: on restore we overwrote pane.directory with the saved
  // CWD, which meant a session in ~/Developer where the user had done
  // `cd test` got relabeled "test" after restore (because sidebarLabel
  // derives the session name from activePane.directory.lastPathComponent).
  // Now: directory preserves the saved initial dir; currentWorkingDirectory
  // carries the live CWD separately.
  func test_restore_preservesInitialPaneDirectorySeparateFromLiveCWD() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL
    let subdir = tmp.appendingPathComponent("state-restoration-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: subdir) }
    let snapshot = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 1,
          sessions: [
            SessionSnapshot(
              id: 1, name: "w",
              directory: tmp,
              lastActivatedAt: Date(),
              tabs: [
                TabSnapshot(
                  id: 1,
                  layout: .leaf(pane: PaneSnapshot(
                    id: 1,
                    directory: tmp,
                    currentWorkingDirectory: subdir,
                    captured: nil
                  )),
                  activePaneID: 1
                ),
              ],
              activeTabID: 1
            ),
          ],
          activeSessionID: 1
        ),
      ],
      activeWindowID: 1
    )
    store.restore(from: snapshot, config: RestoreConfig())
    let restoredState = firstRestoredState()!
    let pane = restoredState.sessions[0].tabs[0].panes[0]
    XCTAssertEqual(pane.directory, tmp,
      "pane.directory should preserve the snapshot's initial directory so the session label stays anchored")
    XCTAssertEqual(pane.currentWorkingDirectory, subdir,
      "pane.currentWorkingDirectory should carry the cd'd-into subfolder; surface view uses this as spawn dir")
  }

  // When the snapshot has no live CWD (pane never emitted OSC 7 before
  // quit — rare but possible for a short-lived pane), currentWorkingDirectory
  // stays nil on the restored pane and the shell spawns in the initial
  // directory via surfaceView's `currentWorkingDirectory ?? directory`
  // fallback.
  func test_restore_nilCurrentWorkingDirectoryLeavesCWDNil() {
    let snapshot = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 1,
          sessions: [
            SessionSnapshot(
              id: 1, name: "w",
              directory: URL(fileURLWithPath: "/tmp"),
              lastActivatedAt: Date(),
              tabs: [
                TabSnapshot(
                  id: 1,
                  layout: .leaf(pane: PaneSnapshot(
                    id: 1,
                    directory: URL(fileURLWithPath: "/tmp"),
                    currentWorkingDirectory: nil,
                    captured: nil
                  )),
                  activePaneID: 1
                ),
              ],
              activeTabID: 1
            ),
          ],
          activeSessionID: 1
        ),
      ],
      activeWindowID: 1
    )
    store.restore(from: snapshot, config: RestoreConfig())
    let restoredState = firstRestoredState()!
    let pane = restoredState.sessions[0].tabs[0].panes[0]
    XCTAssertEqual(pane.directory, URL(fileURLWithPath: "/tmp"))
    XCTAssertNil(pane.currentWorkingDirectory)
  }

  func test_restore_missingDirectoryFallsBackToHome() {
    let missing = URL(fileURLWithPath: "/definitely/not/real/path-\(UUID().uuidString)")
    let snapshot = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 1,
          sessions: [
            SessionSnapshot(
              id: 1, name: "w",
              directory: URL(fileURLWithPath: "/tmp"),
              lastActivatedAt: Date(),
              tabs: [
                TabSnapshot(
                  id: 1,
                  layout: .leaf(pane: PaneSnapshot(
                    id: 1,
                    directory: missing,
                    currentWorkingDirectory: missing,
                    captured: nil
                  )),
                  activePaneID: 1
                ),
              ],
              activeTabID: 1
            ),
          ],
          activeSessionID: 1
        ),
      ],
      activeWindowID: 1
    )
    store.restore(from: snapshot, config: RestoreConfig())
    let restoredState = firstRestoredState()!
    let home = FileManager.default.homeDirectoryForCurrentUser
    XCTAssertEqual(restoredState.sessions[0].tabs[0].panes[0].directory, home)
  }

  func test_restore_roundTrip_preservesStructure() {
    let s = state.createSession(name: "w", directory: URL(fileURLWithPath: "/tmp"))
    s.tabs[0].splitActivePane(direction: .vertical)
    s.addTab()
    let snapshot = store.takeSnapshot()
    let secondStore = WindowsStore()
    secondStore.restore(from: snapshot, config: RestoreConfig())
    let restoredState = secondStore.pendingRestoreStates[0]
    let beforeIDs = s.tabs.map { $0.id }
    let afterIDs = restoredState.sessions[0].tabs.map { $0.id }
    XCTAssertEqual(beforeIDs, afterIDs)
    XCTAssertEqual(restoredState.sessions[0].tabs[0].panes.count, 2)
  }

  func test_restore_unsupportedVersionPreservesExistingSessions() {
    _ = state.createSession(name: "existing", directory: URL(fileURLWithPath: "/tmp"))
    var bad = WorkspaceSnapshot(version: 999, windows: [], activeWindowID: nil)
    // unsupportedVersion is set by the decoder, not the public init —
    // mimic that here so restore() short-circuits.
    bad.unsupportedVersion = 999
    store.restore(from: bad, config: RestoreConfig())
    // restore() short-circuits on unsupported version; the existing window
    // state and its sessions are left intact in windows.
    XCTAssertEqual(store.windows.count, 1)
    XCTAssertEqual(store.windows[0].sessions.count, 1)
    XCTAssertEqual(store.windows[0].sessions[0].name, "existing")
  }

  func test_restore_resolvesAllowlistedCommandIntoPane() {
    let snapshot = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 1,
          sessions: [
            SessionSnapshot(
              id: 1, name: "w",
              directory: URL(fileURLWithPath: "/tmp"),
              lastActivatedAt: Date(),
              tabs: [
                TabSnapshot(
                  id: 1,
                  layout: .leaf(pane: PaneSnapshot(
                    id: 1,
                    directory: URL(fileURLWithPath: "/tmp"),
                    currentWorkingDirectory: URL(fileURLWithPath: "/tmp"),
                    captured: CapturedProcess(executable: "nvim", argv: ["nvim", "foo.txt"])
                  )),
                  activePaneID: 1
                ),
              ],
              activeTabID: 1
            ),
          ],
          activeSessionID: 1
        ),
      ],
      activeWindowID: 1
    )
    let config = RestoreConfig(commands: [.init(match: "nvim", strategy: nil)])
    store.restore(from: snapshot, config: config)
    let restoredState = firstRestoredState()!
    let pane = restoredState.sessions[0].tabs[0].panes[0]
    XCTAssertEqual(pane.command, "nvim foo.txt")
    // Restored commands run via initial_input (login-shell exec wrap) so
    // they pick up the user's PATH / rc — mirrors SSH pane setup.
    XCTAssertFalse(pane.useCommandField)
  }

  func test_restore_unmatchedCapturedProcessLeavesPaneBareShell() {
    let snapshot = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 1,
          sessions: [
            SessionSnapshot(
              id: 1, name: "w",
              directory: URL(fileURLWithPath: "/tmp"),
              lastActivatedAt: Date(),
              tabs: [
                TabSnapshot(
                  id: 1,
                  layout: .leaf(pane: PaneSnapshot(
                    id: 1,
                    directory: URL(fileURLWithPath: "/tmp"),
                    currentWorkingDirectory: URL(fileURLWithPath: "/tmp"),
                    captured: CapturedProcess(executable: "htop", argv: ["htop"])
                  )),
                  activePaneID: 1
                ),
              ],
              activeTabID: 1
            ),
          ],
          activeSessionID: 1
        ),
      ],
      activeWindowID: 1
    )
    store.restore(from: snapshot, config: RestoreConfig())  // no rules
    let restoredState = firstRestoredState()!
    let pane = restoredState.sessions[0].tabs[0].panes[0]
    XCTAssertNil(pane.command)
  }
}
