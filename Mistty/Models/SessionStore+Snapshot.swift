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
              layout: snapshotLayout(tab.layout.root, activePaneID: tab.activePane?.id),
              activePaneID: tab.activePane?.id
            )
          },
          activeTabID: session.activeTab?.id
        )
      },
      activeSessionID: activeSession?.id
    )
  }

  private func snapshotLayout(
    _ node: PaneLayoutNode,
    activePaneID: Int?
  ) -> LayoutNodeSnapshot {
    switch node {
    case .leaf(let pane):
      return .leaf(pane: PaneSnapshot(
        id: pane.id,
        directory: pane.directory,
        currentWorkingDirectory: pane.currentWorkingDirectory,
        captured: nil  // filled in by Phase 2
      ))
    case .empty:
      // Shouldn't appear in a healthy tree, but emit a placeholder leaf with
      // id 0 rather than crashing. The decoder treats id 0 as a sentinel.
      return .leaf(pane: PaneSnapshot(id: 0))
    case .split(let dir, let a, let b, let ratio):
      return .split(
        direction: dir == .horizontal ? .horizontal : .vertical,
        a: snapshotLayout(a, activePaneID: activePaneID),
        b: snapshotLayout(b, activePaneID: activePaneID),
        ratio: Double(ratio)
      )
    }
  }
}
