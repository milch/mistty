import Foundation
import MisttyShared

extension WindowsStore {
  func takeSnapshot() -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      version: WorkspaceSnapshot.currentVersion,
      windows: windows.map { window in
        WindowSnapshot(
          id: window.id,
          sessions: window.sessions.map { session in
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
          activeSessionID: window.activeSession?.id
        )
      },
      activeWindowID: activeWindow?.id
    )
  }

  func restore(from snapshot: WorkspaceSnapshot, config: RestoreConfig) {
    if let unsupported = snapshot.unsupportedVersion {
      DebugLog.shared.log(
        "restore",
        "unsupported snapshot version \(unsupported); starting empty")
      return
    }

    // Clear current state. Windows are stored fresh from snapshot.
    let existing = windows
    for state in existing { closeWindow(state) }

    var maxWindowID = 0, maxSessionID = 0, maxTabID = 0, maxPaneID = 0

    for windowSnap in snapshot.windows {
      maxWindowID = max(maxWindowID, windowSnap.id)
      let state = WindowState(id: windowSnap.id, store: self)

      for sessionSnap in windowSnap.sessions {
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

        for tab in session.tabs { session.closeTab(tab) }

        for tabSnap in sessionSnap.tabs {
          maxTabID = max(maxTabID, tabSnap.id)
          let tab = Self.restoreTab(
            from: tabSnap, paneIDGen: paneIDGen,
            config: config, maxPaneID: &maxPaneID)
          session.addTabByRestore(tab)
        }

        if let activeTabID = sessionSnap.activeTabID,
           let activeTab = session.tabs.first(where: { $0.id == activeTabID }) {
          session.activeTab = activeTab
        } else {
          session.activeTab = session.tabs.first
        }

        state.appendRestoredSession(session)
      }

      if let activeID = windowSnap.activeSessionID,
         let active = state.sessions.first(where: { $0.id == activeID }) {
        state.activeSession = active
      } else {
        state.activeSession = state.sessions.first
      }

      // Push to the FIFO queue; mounting WindowRootViews claim it on appear.
      pendingRestoreStates.append(state)
    }

    advanceIDCounters(
      windowMax: maxWindowID,
      sessionMax: maxSessionID,
      tabMax: maxTabID,
      paneMax: maxPaneID,
      popupMax: 0)

    // activeWindow is wired up post-mount once the NSWindows actually exist.
    pendingActiveWindowID = snapshot.activeWindowID
  }

  // Snapshot restore helpers:

  static func restoreTab(
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

  static func restoreLayoutNode(
    _ snapshot: LayoutNodeSnapshot,
    config: RestoreConfig,
    panes: inout [Int: MisttyPane],
    maxPaneID: inout Int
  ) -> PaneLayoutNode {
    switch snapshot {
    case .leaf(let paneSnap):
      maxPaneID = max(maxPaneID, paneSnap.id)
      let pane = MisttyPane(id: paneSnap.id)
      pane.directory = resolveCWD(paneSnap.directory)
      pane.currentWorkingDirectory = resolveCWD(paneSnap.currentWorkingDirectory)
      if let captured = paneSnap.captured,
         let command = config.resolve(captured) {
        pane.command = command
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

  static func resolveCWD(_ url: URL?) -> URL? {
    guard let url else { return nil }
    let path = url.path
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
      return url
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  func snapshotLayout(_ node: PaneLayoutNode) -> LayoutNodeSnapshot {
    switch node {
    case .leaf(let pane):
      let captured = ForegroundProcessResolver.current(for: pane).map {
        CapturedProcess(executable: $0.executable, argv: $0.argv, pid: $0.pid)
      }
      return .leaf(pane: PaneSnapshot(
        id: pane.id,
        directory: pane.directory,
        currentWorkingDirectory: pane.currentWorkingDirectory,
        captured: captured
      ))
    case .empty:
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
