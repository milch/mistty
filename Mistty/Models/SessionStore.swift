import Foundation

@Observable
@MainActor
final class SessionStore {
  private(set) var sessions: [MisttySession] = []
  var activeSession: MisttySession?

  private var nextSessionId = 1
  private var nextTabId = 1
  private var nextPaneId = 1

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
  func createSession(name: String, directory: URL) -> MisttySession {
    let session = MisttySession(
      id: generateSessionID(),
      name: name,
      directory: directory,
      tabIDGenerator: { [weak self] in self?.generateTabID() ?? 0 },
      paneIDGenerator: { [weak self] in self?.generatePaneID() ?? 0 }
    )
    sessions.append(session)
    activeSession = session
    return session
  }

  func closeSession(_ session: MisttySession) {
    sessions.removeAll { $0.id == session.id }
    if activeSession?.id == session.id { activeSession = sessions.last }
  }
}
