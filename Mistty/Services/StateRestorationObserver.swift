import AppKit
import Foundation

@MainActor
final class StateRestorationObserver {
  let store: SessionStore

  init(store: SessionStore) {
    self.store = store
    reobserve()
  }

  private func reobserve() {
    withObservationTracking {
      _ = snapshotKeys()
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        NSApp?.invalidateRestorableState()
        self?.reobserve()
      }
    }
  }

  /// Touches every observable field that flows into `WorkspaceSnapshot`.
  /// `@Observable` tracks each read; any mutation causes `reobserve` to
  /// re-fire and post the invalidation.
  private func snapshotKeys() -> Int {
    var h = 0
    h ^= store.sessions.count
    if let active = store.activeSession { h ^= active.id }
    for session in store.sessions {
      h ^= session.id ^ session.name.hashValue
      h ^= session.customName?.hashValue ?? 0
      h ^= session.sshCommand?.hashValue ?? 0
      h ^= session.tabs.count
      if let activeTab = session.activeTab { h ^= activeTab.id }
      for tab in session.tabs {
        h ^= tab.id ^ (tab.customTitle?.hashValue ?? 0)
        if let activePane = tab.activePane { h ^= activePane.id }
        for pane in tab.panes {
          h ^= pane.id
          h ^= pane.directory?.absoluteString.hashValue ?? 0
          h ^= pane.currentWorkingDirectory?.absoluteString.hashValue ?? 0
        }
        if case .split(_, _, _, let ratio) = tab.layout.root {
          h ^= Int(ratio * 1000)
        }
      }
    }
    return h
  }
}
