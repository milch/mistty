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
    case .runningSession(let s): return s.name
    case .directory(let u): return u.lastPathComponent
    case .sshHost(let h): return h.alias
    case .newSession(let query, let directory, let createDir, let sshCommand):
      if sshCommand != nil {
        let hostname = query.drop(while: { $0 != " " }).dropFirst().trimmingCharacters(
          in: .whitespaces)
        return "New SSH session: \(hostname)"
      } else if createDir {
        return "New session + create directory: \(directory.path)"
      } else {
        let name =
          query.contains("/") || query.hasPrefix("~")
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

  var symbolName: String {
    switch self {
    case .runningSession: return "terminal.fill"
    case .directory: return "folder"
    case .sshHost: return "network"
    case .newSession: return "plus.circle"
    }
  }

  var isRunningSession: Bool {
    if case .runningSession = self { return true }
    return false
  }

  var lastActivatedAt: Date? {
    if case .runningSession(let s) = self { return s.lastActivatedAt }
    return nil
  }
}

@Observable
@MainActor
final class SessionManagerViewModel {
  /// Multiplier applied to subtitle (path/hostname) match scores so a clean
  /// hit on the displayName outranks a scattered hit across a long subtitle.
  private static let subtitlePenalty: Double = 0.6

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
      // Running sessions always come first, ordered by most recently activated.
      if a.isRunningSession != b.isRunningSession { return a.isRunningSession }
      if a.isRunningSession {
        let aDate = a.lastActivatedAt ?? .distantPast
        let bDate = b.lastActivatedAt ?? .distantPast
        if aDate != bDate { return aDate > bDate }
      }
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
  private func matchableFields(for item: SessionManagerItem) -> (
    rawName: String, subtitle: String?, prefixLen: Int
  ) {
    switch item {
    case .runningSession(let s):
      return (s.name, nil, 0)
    case .directory(let u):
      return (u.lastPathComponent, u.path, 0)
    case .sshHost(let h):
      return (h.alias, h.hostname, 0)
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

        // Subtitle matches are penalized so a clean displayName hit beats a
        // scattered match across a long path. Without this, a query like
        // "mist" can pick up boundary bonuses in
        // "/Users/manu/Developer/ha-is-there-..." and outscore "mistty".
        let subtitleScore = subtitleMatch.map { $0.score * Self.subtitlePenalty }

        if let dm = displayMatch, let sm = subtitleMatch, let ss = subtitleScore {
          if dm.score >= ss {
            minScore = min(minScore, dm.score)
            displayIndices.append(contentsOf: dm.matchedIndices.map { $0 + fields.prefixLen })
          } else {
            minScore = min(minScore, ss)
            subtitleIndices.append(contentsOf: sm.matchedIndices)
          }
        } else if let dm = displayMatch {
          minScore = min(minScore, dm.score)
          displayIndices.append(contentsOf: dm.matchedIndices.map { $0 + fields.prefixLen })
        } else if let sm = subtitleMatch, let ss = subtitleScore {
          minScore = min(minScore, ss)
          subtitleIndices.append(contentsOf: sm.matchedIndices)
        } else {
          allTokensMatch = false
          break
        }
      }

      guard allTokensMatch else { continue }

      var finalScore = minScore

      // Running session boost — prefer existing sessions over directories/SSH hosts
      // when match quality is comparable.
      if case .runningSession = item {
        finalScore = min(finalScore * 1.5, 1.0)
      }

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

    // Prepend "New" option
    if let newItem = resolveNewOption(query: query) {
      filteredItems.insert(newItem, at: 0)
      // Select first real match (index 1) if available, otherwise select "New" (index 0)
      selectedIndex = filteredItems.count > 1 ? 1 : 0
    } else {
      selectedIndex = 0
    }
  }

  func moveUp() { selectedIndex = max(0, selectedIndex - 1) }
  func moveDown() { selectedIndex = min(filteredItems.count - 1, selectedIndex + 1) }

  func completionValue() -> String? {
    guard selectedIndex < filteredItems.count else { return nil }
    let item = filteredItems[selectedIndex]
    switch item {
    case .newSession: return nil
    case .runningSession(let s): return s.name
    case .directory(let u): return u.path
    case .sshHost(let h): return h.alias
    }
  }

  private func categoryOrder(_ item: SessionManagerItem) -> Int {
    switch item {
    case .runningSession: return 0
    case .directory: return 1
    case .sshHost: return 2
    case .newSession: return -1
    }
  }

  private func resolveNewOption(query: String) -> SessionManagerItem? {
    let tokens = query.split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return nil }

    let fm = FileManager.default

    // SSH-like: starts with "ssh "
    if tokens.first?.lowercased() == "ssh" {
      let hostname = query.drop(while: { $0 != " " }).dropFirst()
        .trimmingCharacters(in: .whitespaces)
      guard !hostname.isEmpty else { return nil }

      let config = MisttyConfig.load()
      let command = config.ssh.resolveCommand(for: hostname)
      let fullCommand = "\(command) \(hostname)"
      return .newSession(
        query: query,
        directory: fm.homeDirectoryForCurrentUser,
        createDirectory: false,
        sshCommand: fullCommand
      )
    }

    // Path-like: contains "/" or starts with "~"
    if query.contains("/") || query.hasPrefix("~") {
      let expanded = (query as NSString).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded).standardized

      var isDir: ObjCBool = false
      if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
        if !isDir.boolValue { return nil }  // points to a file
        return .newSession(query: query, directory: url, createDirectory: false, sshCommand: nil)
      }

      // Check parent exists
      let parent = url.deletingLastPathComponent()
      var parentIsDir: ObjCBool = false
      if fm.fileExists(atPath: parent.path, isDirectory: &parentIsDir), parentIsDir.boolValue {
        return .newSession(query: query, directory: url, createDirectory: true, sshCommand: nil)
      }

      return nil  // parent doesn't exist
    }

    // Plain text: create session with query as name in active pane's CWD
    let directory =
      store.activeSession?.activeTab?.activePane?.directory
      ?? store.activeSession?.directory
      ?? fm.homeDirectoryForCurrentUser
    return .newSession(query: query, directory: directory, createDirectory: false, sshCommand: nil)
  }

  func confirmSelection(modifierFlags: NSEvent.ModifierFlags = []) {
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

    case .newSession(let query, var directory, let createDir, let sshCommand):
      let fm = FileManager.default

      // Cmd modifier overrides to home
      if modifierFlags.contains(.command) {
        directory = fm.homeDirectoryForCurrentUser
      }

      if let sshCommand {
        let hostname = query.drop(while: { $0 != " " }).dropFirst()
          .trimmingCharacters(in: .whitespaces)
        let session = store.createSession(
          name: hostname,
          directory: fm.homeDirectoryForCurrentUser,
          exec: sshCommand
        )
        session.sshCommand = sshCommand
      } else {
        // Create directory if needed (use withIntermediateDirectories: true
        // to handle race condition where directory was created between filter and confirm)
        if createDir {
          try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let isPathLike = query.contains("/") || query.hasPrefix("~")
        let name = isPathLike ? directory.lastPathComponent : query
        // When the user typed a plain-text name (not a path, not SSH),
        // record it as customName so the sidebar shows it verbatim even if
        // the active pane's CWD changes later.
        let customName: String? = isPathLike ? nil : query
        store.createSession(name: name, directory: directory, customName: customName)
      }

      // Record frecency for the new session
      let sessionName =
        sshCommand != nil
        ? query.drop(while: { $0 != " " }).dropFirst().trimmingCharacters(in: .whitespaces)
        : (query.contains("/") || query.hasPrefix("~") ? directory.lastPathComponent : query)
      frecencyService.recordAccess(for: "session:\(sessionName)")
    }
  }
}
