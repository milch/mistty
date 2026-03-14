import AppKit
import Foundation

struct ItemMatchResult {
  let score: Double
  let displayNameIndices: [Int]
  let subtitleIndices: [Int]
}

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
  var matchResults: [String: ItemMatchResult] = [:]

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

  /// Returns (rawName, subtitle, displayNamePrefixLength) for fuzzy matching.
  private func matchableFields(for item: SessionManagerItem) -> (rawName: String, subtitle: String?, prefixLen: Int) {
    switch item {
    case .runningSession(let s):
      return (s.name, nil, 2) // "▶ " is 2 chars
    case .directory(let u):
      return (u.lastPathComponent, u.path, 0)
    case .sshHost(let h):
      return (h.alias, h.hostname, 2) // "⌁ " is 2 chars
    case .newSession:
      return ("", nil, 0)
    }
  }

  private func applyFilter() {
    matchResults = [:]

    let tokens = query.split(separator: " ").map(String.init)

    if tokens.isEmpty {
      filteredItems = allItems
      selectedIndex = 0
      return
    }

    let isSSHQuery = tokens.first?.lowercased() == "ssh"

    struct ScoredItem {
      let item: SessionManagerItem
      let result: ItemMatchResult
    }

    var scored: [ScoredItem] = []

    for item in allItems {
      let fields = matchableFields(for: item)

      var allTokensMatch = true
      var minScore = Double.infinity
      var displayIndices: [Int] = []
      var subtitleIndices: [Int] = []

      for token in tokens {
        let displayMatch = FuzzyMatcher.match(query: token, target: fields.rawName)
        let subtitleMatch = fields.subtitle.flatMap { FuzzyMatcher.match(query: token, target: $0) }

        if let dm = displayMatch, let sm = subtitleMatch {
          if dm.score >= sm.score {
            minScore = min(minScore, dm.score)
            displayIndices.append(contentsOf: dm.matchedIndices.map { $0 + fields.prefixLen })
          } else {
            minScore = min(minScore, sm.score)
            subtitleIndices.append(contentsOf: sm.matchedIndices)
          }
        } else if let dm = displayMatch {
          minScore = min(minScore, dm.score)
          displayIndices.append(contentsOf: dm.matchedIndices.map { $0 + fields.prefixLen })
        } else if let sm = subtitleMatch {
          minScore = min(minScore, sm.score)
          subtitleIndices.append(contentsOf: sm.matchedIndices)
        } else {
          allTokensMatch = false
          break
        }
      }

      guard allTokensMatch else { continue }

      var finalScore = minScore

      // SSH boost
      if isSSHQuery, case .sshHost = item {
        finalScore = min(finalScore * 1.5, 1.0)
      }

      let result = ItemMatchResult(
        score: finalScore,
        displayNameIndices: displayIndices,
        subtitleIndices: subtitleIndices
      )
      scored.append(ScoredItem(item: item, result: result))
    }

    // Sort by score desc, frecency as tiebreaker
    scored.sort { a, b in
      if a.result.score != b.result.score { return a.result.score > b.result.score }
      let freqA = a.item.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      let freqB = b.item.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      return freqA > freqB
    }

    filteredItems = scored.map(\.item)
    for s in scored {
      matchResults[s.item.id] = s.result
    }

    selectedIndex = 0
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
