import Foundation
import MisttyShared

extension SessionStore {
  func takeSnapshot() -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      version: WorkspaceSnapshot.currentVersion,
      sessions: sessions.map { session in
        SessionSnapshot(
          id: session.id,
          name: session.name,
          customName: session.customName,
          directory: session.directory,
          sshCommand: session.sshCommand,
          lastActivatedAt: session.lastActivatedAt,
          tabs: session.tabs.map { tab in
            TabSnapshot(
              id: tab.id,
              customTitle: tab.customTitle,
              directory: tab.directory,
              layout: snapshotLayout(tab.layout.root),
              activePaneID: tab.activePane?.id
            )
          },
          activeTabID: session.activeTab?.id
        )
      },
      activeSessionID: activeSession?.id
    )
  }

  func restore(from snapshot: WorkspaceSnapshot, config: RestoreConfig) {
    guard snapshot.unsupportedVersion == nil else {
      DebugLog.shared.log(
        "restore",
        "unsupported snapshot version \(snapshot.version); starting empty")
      return
    }

    // Clear anything currently in the store before reconstructing.
    // Copy the array first — closeSession mutates `sessions` in place.
    let existing = sessions
    for session in existing { closeSession(session) }

    var maxSessionID = 0, maxTabID = 0, maxPaneID = 0

    for sessionSnap in snapshot.sessions {
      maxSessionID = max(maxSessionID, sessionSnap.id)
      let tabIDGen: () -> Int = { [weak self] in self?.generateTabID() ?? 0 }
      let paneIDGen: () -> Int = { [weak self] in self?.generatePaneID() ?? 0 }
      let popupIDGen: () -> Int = { [weak self] in self?.generatePopupID() ?? 0 }

      let session = MisttySession(
        id: sessionSnap.id,
        name: sessionSnap.name,
        directory: sessionSnap.directory,
        exec: nil,
        customName: sessionSnap.customName,
        tabIDGenerator: tabIDGen,
        paneIDGenerator: paneIDGen,
        popupIDGenerator: popupIDGen
      )
      session.sshCommand = sessionSnap.sshCommand
      session.lastActivatedAt = sessionSnap.lastActivatedAt

      // `MisttySession.init` adds a default tab; drop it before restoring.
      for tab in session.tabs { session.closeTab(tab) }

      for tabSnap in sessionSnap.tabs {
        maxTabID = max(maxTabID, tabSnap.id)
        let tab = Self.restoreTab(
          from: tabSnap,
          paneIDGen: paneIDGen,
          config: config,
          maxPaneID: &maxPaneID
        )
        session.addTabByRestore(tab)
      }

      if let activeTabID = sessionSnap.activeTabID,
         let activeTab = session.tabs.first(where: { $0.id == activeTabID }) {
        session.activeTab = activeTab
      } else {
        session.activeTab = session.tabs.first
      }

      appendRestoredSession(session)
    }

    if let activeID = snapshot.activeSessionID,
       let active = sessions.first(where: { $0.id == activeID }) {
      activeSession = active
    } else {
      activeSession = sessions.first
    }

    advanceIDCounters(
      sessionMax: maxSessionID, tabMax: maxTabID, paneMax: maxPaneID)
  }

  private static func restoreTab(
    from snapshot: TabSnapshot,
    paneIDGen: @escaping () -> Int,
    config: RestoreConfig,
    maxPaneID: inout Int
  ) -> MisttyTab {
    var panes: [Int: MisttyPane] = [:]
    let rootNode = restoreLayoutNode(
      snapshot.layout, config: config, panes: &panes, maxPaneID: &maxPaneID)

    guard let firstPane = panes.values.first else {
      let pane = MisttyPane(id: paneIDGen())
      let tab = MisttyTab(id: snapshot.id, existingPane: pane, paneIDGenerator: paneIDGen)
      return tab
    }
    let tab = MisttyTab(
      id: snapshot.id, existingPane: firstPane, paneIDGenerator: paneIDGen)
    tab.customTitle = snapshot.customTitle
    tab.layout = PaneLayout(root: rootNode)
    tab.refreshPanesFromLayout()

    if let activeID = snapshot.activePaneID,
       let active = tab.panes.first(where: { $0.id == activeID }) {
      tab.activePane = active
    } else {
      tab.activePane = tab.panes.first
    }

    return tab
  }

  private static func restoreLayoutNode(
    _ snapshot: LayoutNodeSnapshot,
    config: RestoreConfig,
    panes: inout [Int: MisttyPane],
    maxPaneID: inout Int
  ) -> PaneLayoutNode {
    switch snapshot {
    case .leaf(let paneSnap):
      maxPaneID = max(maxPaneID, paneSnap.id)
      let pane = MisttyPane(id: paneSnap.id)
      pane.directory = resolveCWD(
        paneSnap.currentWorkingDirectory ?? paneSnap.directory)
      pane.currentWorkingDirectory = paneSnap.currentWorkingDirectory
      if let captured = paneSnap.captured,
         let command = config.resolve(captured) {
        pane.command = command
        // Route through the login shell so the restored command picks up
        // PATH / aliases / env from rc files. Unlike SSH panes we do NOT
        // prefix with `exec` — when the user quits (e.g. `:q` in nvim) we
        // want the shell prompt to come back, not the pane to close.
        pane.useCommandField = false
        pane.execInitialInput = false
      }
      panes[paneSnap.id] = pane
      return .leaf(pane)
    case .split(let dir, let a, let b, let ratio):
      let aNode = restoreLayoutNode(a, config: config, panes: &panes, maxPaneID: &maxPaneID)
      let bNode = restoreLayoutNode(b, config: config, panes: &panes, maxPaneID: &maxPaneID)
      let direction: SplitDirection = (dir == .horizontal) ? .horizontal : .vertical
      return .split(direction, aNode, bNode, CGFloat(ratio))
    }
  }

  /// Pane directories that no longer exist fall back to the user's home
  /// directory so the spawned shell doesn't die immediately with "no such
  /// file." Matches behavior spelled out in the spec.
  private static func resolveCWD(_ url: URL?) -> URL? {
    guard let url else { return nil }
    let path = url.path
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
      return url
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  private func snapshotLayout(_ node: PaneLayoutNode) -> LayoutNodeSnapshot {
    switch node {
    case .leaf(let pane):
      let captured = ForegroundProcessResolver.current(for: pane).map {
        CapturedProcess(executable: $0.executable, argv: $0.argv)
      }
      return .leaf(pane: PaneSnapshot(
        id: pane.id,
        directory: pane.directory,
        currentWorkingDirectory: pane.currentWorkingDirectory,
        captured: captured
      ))
    case .empty:
      // PaneLayoutNode.empty is a transient state that should never appear in a
      // live layout at snapshot time. In debug builds, assert to surface the bug;
      // in release, emit an id: 0 leaf so the snapshot still round-trips (Task 6's
      // decoder will restore a pane with id 0, which is a minor corruption but
      // better than crashing the user's state save).
      assertionFailure("PaneLayoutNode.empty in live tree at snapshot time")
      return .leaf(pane: PaneSnapshot(id: 0))
    case .split(let dir, let a, let b, let ratio):
      return .split(
        direction: dir == .horizontal ? .horizontal : .vertical,
        a: snapshotLayout(a),
        b: snapshotLayout(b),
        ratio: Double(ratio)
      )
    }
  }
}
