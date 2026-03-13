import Foundation

@Observable
@MainActor
final class SessionStore {
  private(set) var sessions: [MisttySession] = []
  var activeSession: MisttySession?

  @discardableResult
  func createSession(name: String, directory: URL) -> MisttySession {
    let session = MisttySession(name: name, directory: directory)
    sessions.append(session)
    activeSession = session
    return session
  }

  func closeSession(_ session: MisttySession) {
    sessions.removeAll { $0.id == session.id }
    if activeSession?.id == session.id { activeSession = sessions.last }
  }
}
