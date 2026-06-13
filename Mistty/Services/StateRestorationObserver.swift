import AppKit
import Foundation

@MainActor
final class StateRestorationObserver {
  let windowsStore: WindowsStore

  /// Trailing debounce for invalidation. A divider drag mutates layout
  /// ratios on every tick and each mutation re-fires onChange; observation
  /// is re-armed immediately (so no mutation is missed) but the
  /// invalidateRestorableState calls are coalesced — the eventual
  /// restorable-state encode walks every pane's foreground process tree.
  private var pendingInvalidation: DispatchWorkItem?

  init(windowsStore: WindowsStore) {
    self.windowsStore = windowsStore
    reobserve()
  }

  private func reobserve() {
    withObservationTracking {
      _ = snapshotKeys()
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.reobserve()
        self.pendingInvalidation?.cancel()
        let work = DispatchWorkItem { NSApp?.invalidateRestorableState() }
        self.pendingInvalidation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
      }
    }
  }

  /// Touches every observable field that flows into `WorkspaceSnapshot`.
  /// `@Observable` tracks each read; any mutation causes `reobserve` to
  /// re-fire and post the invalidation.
  ///
  /// The XOR-accumulated hash value is intentionally discarded — all
  /// that matters is that we *read* each tracked field inside the
  /// `withObservationTracking` closure. Observation tracking triggers
  /// on property *access*, not hash equality, so we don't need a
  /// collision-free digest; we just need every mutation point to touch
  /// one of the accessed properties.
  private func snapshotKeys() -> Int {
    var h = 0
    h ^= windowsStore.windows.count
    if let activeWindow = windowsStore.activeWindow { h ^= activeWindow.id }
    for window in windowsStore.windows {
      h ^= window.id
      h ^= window.sessions.count
      if let active = window.activeSession { h ^= active.id }
      for session in window.sessions {
        h ^= session.id ^ session.name.hashValue
        h ^= session.customName?.hashValue ?? 0
        h ^= session.sshCommand?.hashValue ?? 0
        h ^= session.directory.absoluteString.hashValue
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
          // Observe the layout tree recursively so resizing a nested
          // split divider fires an invalidation too — the top-level
          // `tab.layout` property access already registers an observer,
          // but we also need to touch every split's ratio so changes
          // deeper in the tree propagate through @Observable tracking.
          readLayoutNode(tab.layout.root, hash: &h)
        }
      }
    }
    return h
  }

  private func readLayoutNode(_ node: PaneLayoutNode, hash: inout Int) {
    switch node {
    case .leaf, .empty:
      return
    case .split(let dir, let a, let b, let ratio):
      hash ^= Int(ratio * 1000)
      hash ^= dir.hashValue
      readLayoutNode(a, hash: &hash)
      readLayoutNode(b, hash: &hash)
    }
  }
}
