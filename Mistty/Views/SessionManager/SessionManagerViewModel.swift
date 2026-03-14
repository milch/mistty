import AppKit
import Foundation

@MainActor
enum SessionManagerItem {
  case runningSession(MisttySession)
  case directory(URL)
  case sshHost(SSHHost)
  case newSession(query: String, directory: URL, createDirectory: Bool, sshCommand: String?)

  var id: String {
    switch self {
    case .runningSession(let s): return "session-\(s.id)"
    case .directory(let u): return "dir-\(u.path)"
    case .sshHost(let h): return "ssh-\(h.alias)"
    case .newSession: return "new-session"
    }
  }

  var displayName: String {
    switch self {
    case .runningSession(let s): return "▶ \(s.name)"
    case .directory(let u): return u.lastPathComponent
    case .sshHost(let h): return "⌁ \(h.alias)"
    case .newSession(let query, let directory, let createDir, let sshCommand):
      if sshCommand != nil {
        let hostname = query.drop(while: { $0 != " " }).dropFirst().trimmingCharacters(in: .whitespaces)
        return "New SSH session: \(hostname)"
      } else if createDir {
        return "New session + create directory: \(directory.path)"
      } else {
        let name = query.contains("/") || query.hasPrefix("~")
          ? directory.lastPathComponent : query
        return "New session: \(name)"
      }
    }
  }

  var subtitle: String? {
    switch self {
    case .runningSession: return nil
    case .directory(let u): return u.path
    case .sshHost(let h): return h.hostname
    case .newSession(_, let directory, _, let sshCommand):
      if sshCommand != nil {
        return sshCommand
      }
      return "\(directory.path) (\u{2318} for ~)"
    }
  }

  var frecencyKey: String? {
    switch self {
    case .runningSession(let s): return "session:\(s.name)"
    case .directory(let u): return "dir:\(u.path)"
    case .sshHost(let h): return "ssh:\(h.alias)"
    case .newSession: return nil
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
  private let frecencyService: FrecencyService

  init(store: SessionStore, frecencyService: FrecencyService = FrecencyService()) {
    self.store = store
    self.frecencyService = frecencyService
  }

  func load() async {
    let dirs = await ZoxideService.recentDirectories()
    let sshHosts = SSHConfigService.loadHosts()

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

    allItems = items.sorted { a, b in
      let scoreA = a.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      let scoreB = b.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      if scoreA != scoreB { return scoreA > scoreB }
      return categoryOrder(a) < categoryOrder(b)
    }
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

  private func categoryOrder(_ item: SessionManagerItem) -> Int {
    switch item {
    case .runningSession: return 0
    case .directory: return 1
    case .sshHost: return 2
    case .newSession: return -1
    }
  }

  func confirmSelection() {
    guard selectedIndex < filteredItems.count else { return }
    let item = filteredItems[selectedIndex]
    if let key = item.frecencyKey {
      frecencyService.recordAccess(for: key)
    }
    switch item {
    case .runningSession(let session):
      store.activeSession = session
    case .directory(let url):
      store.createSession(name: url.lastPathComponent, directory: url)
    case .sshHost(let host):
      let config = MisttyConfig.load()
      let command = config.ssh.resolveCommand(for: host.alias)
      let fullCommand = "\(command) \(host.alias)"
      let session = store.createSession(
        name: host.alias,
        directory: FileManager.default.homeDirectoryForCurrentUser,
        exec: fullCommand
      )
      session.sshCommand = fullCommand
    case .newSession:
      break // Full handling added in Task 8
    }
  }
}
