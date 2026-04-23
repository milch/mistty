import AppKit
import Foundation

struct TrackedWindow {
  let id: Int
  let window: NSWindow
}

@Observable
@MainActor
final class SessionStore {
  private(set) var sessions: [MisttySession] = []
  var activeSession: MisttySession? {
    didSet {
      activeSession?.lastActivatedAt = Date()
    }
  }

  var nextSessionId = 1
  var nextTabId = 1
  var nextPaneId = 1
  private var nextWindowId = 1
  var nextPopupId = 1
  private(set) var trackedWindows: [TrackedWindow] = []

  func generateSessionID() -> Int {
    let id = nextSessionId
    nextSessionId += 1
    return id
  }

  func generateTabID() -> Int {
    let id = nextTabId
    nextTabId += 1
    return id
  }

  func generatePaneID() -> Int {
    let id = nextPaneId
    nextPaneId += 1
    return id
  }

  @discardableResult
  func createSession(
    name: String, directory: URL, exec: String? = nil, customName: String? = nil
  ) -> MisttySession {
    let session = MisttySession(
      id: generateSessionID(),
      name: name,
      directory: directory,
      exec: exec,
      customName: customName,
      tabIDGenerator: { [weak self] in
        guard let self else {
          assertionFailure("SessionStore was deallocated while sessions still exist")
          return 0
        }
        return self.generateTabID()
      },
      paneIDGenerator: { [weak self] in
        guard let self else {
          assertionFailure("SessionStore was deallocated while sessions still exist")
          return 0
        }
        return self.generatePaneID()
      },
      popupIDGenerator: { [weak self] in
        guard let self else {
          assertionFailure("SessionStore was deallocated while sessions still exist")
          return 0
        }
        return self.generatePopupID()
      }
    )
    sessions.append(session)
    activeSession = session
    return session
  }

  func closeSession(_ session: MisttySession) {
    sessions.removeAll { $0.id == session.id }
    if activeSession?.id == session.id { activeSession = sessions.last }
  }

  func generatePopupID() -> Int {
    let id = nextPopupId
    nextPopupId += 1
    return id
  }

  // MARK: - Window registry

  private func generateWindowID() -> Int {
    let id = nextWindowId
    nextWindowId += 1
    return id
  }

  func registerWindow(_ window: NSWindow) -> Int {
    if let existing = trackedWindows.first(where: { $0.window === window }) {
      DebugLog.shared.log(
        "window",
        "registerWindow: already tracked id=\(existing.id) num=\(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow) count=\(trackedWindows.count)"
      )
      return existing.id
    }
    let id = generateWindowID()
    trackedWindows.append(TrackedWindow(id: id, window: window))
    DebugLog.shared.log(
      "window",
      "registerWindow: id=\(id) num=\(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow) count=\(trackedWindows.count)"
    )
    return id
  }

  func unregisterWindow(_ window: NSWindow) {
    let before = trackedWindows.count
    let removedIds = trackedWindows
      .filter { $0.window === window }
      .map { $0.id }
    trackedWindows.removeAll { $0.window === window }
    DebugLog.shared.log(
      "window",
      "unregisterWindow: removed=\(removedIds) num=\(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow) count=\(before)→\(trackedWindows.count)"
    )
  }

  func trackedWindow(byId id: Int) -> TrackedWindow? {
    trackedWindows.first { $0.id == id }
  }

  // MARK: - Restore helpers

  /// Append a fully-constructed `MisttySession` during restore. Bypasses
  /// `createSession`'s fresh-ID + default-tab flow because the session is
  /// already hydrated from a snapshot.
  func appendRestoredSession(_ session: MisttySession) {
    sessions.append(session)
  }

  /// Advance the next-ID counters so newly-allocated IDs don't collide with
  /// restored ones. Called once from `restore(from:config:)`.
  func advanceIDCounters(
    sessionMax: Int, tabMax: Int, paneMax: Int, popupMax: Int = 0
  ) {
    nextSessionId = max(nextSessionId, sessionMax + 1)
    nextTabId = max(nextTabId, tabMax + 1)
    nextPaneId = max(nextPaneId, paneMax + 1)
    nextPopupId = max(nextPopupId, popupMax + 1)
  }

  // MARK: - Lookup helpers

  func session(byId id: Int) -> MisttySession? {
    sessions.first { $0.id == id }
  }

  func tab(byId id: Int) -> (session: MisttySession, tab: MisttyTab)? {
    for session in sessions {
      if let tab = session.tabs.first(where: { $0.id == id }) {
        return (session, tab)
      }
    }
    return nil
  }

  func pane(byId id: Int) -> (session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    for session in sessions {
      for tab in session.tabs {
        if let pane = tab.panes.first(where: { $0.id == id }) {
          return (session, tab, pane)
        }
      }
    }
    return nil
  }

  func popup(byId id: Int) -> (session: MisttySession, popup: PopupState)? {
    for session in sessions {
      if let popup = session.popups.first(where: { $0.id == id }) {
        return (session, popup)
      }
    }
    return nil
  }

  func nextSession() {
    guard let current = activeSession,
      let index = sessions.firstIndex(where: { $0.id == current.id }),
      sessions.count > 1
    else { return }
    activeSession = sessions[(index + 1) % sessions.count]
  }

  func prevSession() {
    guard let current = activeSession,
      let index = sessions.firstIndex(where: { $0.id == current.id }),
      sessions.count > 1
    else { return }
    activeSession = sessions[(index - 1 + sessions.count) % sessions.count]
  }

  // Move the active session one slot toward the top/bottom of the list.
  // No-ops at the edges — reorder doesn't wrap.
  func moveActiveSessionUp() {
    guard let current = activeSession,
      let index = sessions.firstIndex(where: { $0.id == current.id }),
      index > 0
    else { return }
    sessions.swapAt(index, index - 1)
  }

  func moveActiveSessionDown() {
    guard let current = activeSession,
      let index = sessions.firstIndex(where: { $0.id == current.id }),
      index < sessions.count - 1
    else { return }
    sessions.swapAt(index, index + 1)
  }

  // Bulk move — matches the signature SwiftUI's `.onMove` hands us, so
  // sidebar drag-to-reorder flows through the same mutation point.
  func moveSessions(from source: IndexSet, to destination: Int) {
    sessions.move(fromOffsets: source, toOffset: destination)
  }

  func activePaneInfo() -> (session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    guard let session = activeSession,
      let tab = session.activeTab,
      let pane = tab.activePane
    else { return nil }
    return (session, tab, pane)
  }

  /// True when the system's key window is a tracked terminal window. Used to
  /// scope app-wide shortcuts (Cmd-W, etc.) so they don't fire while an
  /// auxiliary window like Settings has focus.
  func isTerminalWindowKey() -> Bool {
    guard let key = NSApp.keyWindow else {
      DebugLog.shared.log(
        "cmdw",
        "isTerminalWindowKey=false: no keyWindow, trackedCount=\(trackedWindows.count)"
      )
      return false
    }
    let isTracked = trackedWindows.contains { $0.window === key }
    if !isTracked {
      DebugLog.shared.log(
        "cmdw",
        "isTerminalWindowKey=false: key=\(ObjectIdentifier(key)) num=\(key.windowNumber) title=\"\(key.title)\" class=\(type(of: key)) trackedIds=\(trackedWindows.map(\.id))"
      )
    }
    return isTracked
  }
}
