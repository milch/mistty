import AppKit
import Foundation

@Observable
@MainActor
final class WindowState {
  let id: Int
  unowned let store: WindowsStore
  private(set) var sessions: [MisttySession] = []
  var activeSession: MisttySession? {
    didSet {
      activeSession?.lastActivatedAt = Date()
    }
  }

  init(id: Int, store: WindowsStore) {
    self.id = id
    self.store = store
  }

  // MARK: - Session lifecycle

  @discardableResult
  func createSession(
    name: String, directory: URL, exec: String? = nil, customName: String? = nil
  ) -> MisttySession {
    let session = MisttySession(
      id: store.generateSessionID(),
      name: name,
      directory: directory,
      exec: exec,
      customName: customName,
      tabIDGenerator: { [weak store] in store?.generateTabID() ?? 0 },
      paneIDGenerator: { [weak store] in store?.generatePaneID() ?? 0 },
      popupIDGenerator: { [weak store] in store?.generatePopupID() ?? 0 }
    )
    sessions.append(session)
    activeSession = session
    return session
  }

  func closeSession(_ session: MisttySession) {
    sessions.removeAll { $0.id == session.id }
    if activeSession?.id == session.id { activeSession = sessions.last }
  }

  /// Append a fully-constructed `MisttySession` during restore. Bypasses
  /// `createSession`'s fresh-id + default-tab flow because the session is
  /// already hydrated from a snapshot.
  func appendRestoredSession(_ session: MisttySession) {
    sessions.append(session)
  }

  // MARK: - Navigation

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

  func moveSessions(from source: IndexSet, to destination: Int) {
    sessions.move(fromOffsets: source, toOffset: destination)
  }

  // MARK: - Lookup convenience

  func activePaneInfo() -> (session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    guard let session = activeSession,
      let tab = session.activeTab,
      let pane = tab.activePane
    else { return nil }
    return (session, tab, pane)
  }
}
