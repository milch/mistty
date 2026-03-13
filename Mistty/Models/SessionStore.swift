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
  var activeSession: MisttySession?

  private var nextSessionId = 1
  private var nextTabId = 1
  private var nextPaneId = 1
  private var nextWindowId = 1
  private var nextPopupId = 1
  private(set) var trackedWindows: [TrackedWindow] = []

  private func generateSessionID() -> Int {
    let id = nextSessionId
    nextSessionId += 1
    return id
  }

  private func generateTabID() -> Int {
    let id = nextTabId
    nextTabId += 1
    return id
  }

  private func generatePaneID() -> Int {
    let id = nextPaneId
    nextPaneId += 1
    return id
  }

  @discardableResult
  func createSession(name: String, directory: URL, exec: String? = nil) -> MisttySession {
    let session = MisttySession(
      id: generateSessionID(),
      name: name,
      directory: directory,
      exec: exec,
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

  private func generatePopupID() -> Int {
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
      return existing.id
    }
    let id = generateWindowID()
    trackedWindows.append(TrackedWindow(id: id, window: window))
    return id
  }

  func unregisterWindow(_ window: NSWindow) {
    trackedWindows.removeAll { $0.window === window }
  }

  func trackedWindow(byId id: Int) -> TrackedWindow? {
    trackedWindows.first { $0.id == id }
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

  func activePaneInfo() -> (session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    guard let session = activeSession,
          let tab = session.activeTab,
          let pane = tab.activePane else { return nil }
    return (session, tab, pane)
  }
}
