import Foundation

@MainActor
enum SessionManagerItem {
  case runningSession(MisttySession)
  case directory(URL)
  case sshHost(SSHHost)

  var id: String {
    switch self {
    case .runningSession(let s): return "session-\(s.id)"
    case .directory(let u): return "dir-\(u.path)"
    case .sshHost(let h): return "ssh-\(h.alias)"
    }
  }

  var displayName: String {
    switch self {
    case .runningSession(let s): return "▶ \(s.name)"
    case .directory(let u): return u.lastPathComponent
    case .sshHost(let h): return "⌁ \(h.alias)"
    }
  }

  var subtitle: String? {
    switch self {
    case .runningSession: return nil
    case .directory(let u): return u.path
    case .sshHost(let h): return h.hostname
    }
  }
}

@Observable
@MainActor
final class SessionManagerViewModel {
  var query = ""
  private var allItems: [SessionManagerItem] = []
  var filteredItems: [SessionManagerItem] = []
  var selectedIndex = 0

  let store: SessionStore

  init(store: SessionStore) {
    self.store = store
  }

  func load() async {
    let dirs = await ZoxideService.recentDirectories()
    let sshHosts = SSHConfigService.loadHosts()

    // Directories that already have active sessions
    let activeDirectories = Set(store.sessions.map { $0.directory.standardizedFileURL })

    var items: [SessionManagerItem] = []
    items += store.sessions
      .filter { $0.id != store.activeSession?.id }
      .map { .runningSession($0) }
    items +=
      dirs
      .filter { !activeDirectories.contains($0.standardizedFileURL) }
      .map { .directory($0) }
    items += sshHosts.map { .sshHost($0) }

    allItems = items
    applyFilter()
  }

  func updateQuery(_ newQuery: String) {
    query = newQuery
    applyFilter()
  }

  private func applyFilter() {
    if query.isEmpty {
      filteredItems = allItems
    } else {
      filteredItems = allItems.filter {
        $0.displayName.localizedCaseInsensitiveContains(query)
      }
    }
    selectedIndex = filteredItems.isEmpty ? 0 : 0
  }

  func moveUp() { selectedIndex = max(0, selectedIndex - 1) }
  func moveDown() { selectedIndex = min(filteredItems.count - 1, selectedIndex + 1) }

  func confirmSelection() {
    guard selectedIndex < filteredItems.count else { return }
    switch filteredItems[selectedIndex] {
    case .runningSession(let session):
      store.activeSession = session
    case .directory(let url):
      store.createSession(name: url.lastPathComponent, directory: url)
    case .sshHost:
      break  // post-MVP
    }
  }
}
