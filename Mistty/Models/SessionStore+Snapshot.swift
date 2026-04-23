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

  private func snapshotLayout(_ node: PaneLayoutNode) -> LayoutNodeSnapshot {
    switch node {
    case .leaf(let pane):
      return .leaf(pane: PaneSnapshot(
        id: pane.id,
        directory: pane.directory,
        currentWorkingDirectory: pane.currentWorkingDirectory,
        captured: nil  // filled in by Phase 2
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
