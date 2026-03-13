import Foundation

@Observable
@MainActor
final class SessionStore {
  private(set) var sessions: [MisttySession] = []
  var activeSession: MisttySession?

  private var nextSessionId = 1
  private var nextTabId = 1
  private var nextPaneId = 1

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

  func activePaneInfo() -> (session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    guard let session = activeSession,
          let tab = session.activeTab,
          let pane = tab.activePane else { return nil }
    return (session, tab, pane)
  }
}
