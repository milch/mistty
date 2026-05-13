import AppKit
import Foundation

@MainActor
enum DirectoryPickerItem {
  case directory(URL)
  /// Path-like query that resolves to a missing directory whose parent
  /// exists. Picking it `mkdir -p`s before reparenting.
  case newDirectory(query: String, url: URL)

  var id: String {
    switch self {
    case .directory(let u): return "dir-\(u.path)"
    case .newDirectory(_, let u): return "newdir-\(u.path)"
    }
  }

  var displayName: String {
    switch self {
    case .directory(let u): return u.lastPathComponent
    case .newDirectory(_, let u):
      return "Create + reparent to \(u.path)"
    }
  }

  var subtitle: String? {
    switch self {
    case .directory(let u): return u.path
    case .newDirectory(_, let u): return u.deletingLastPathComponent().path
    }
  }

  var frecencyKey: String? {
    switch self {
    case .directory(let u): return "dir:\(u.path)"
    case .newDirectory: return nil
    }
  }

  var symbolName: String {
    switch self {
    case .directory: return "folder"
    case .newDirectory: return "folder.badge.plus"
    }
  }

  var resolvedURL: URL? {
    switch self {
    case .directory(let u): return u
    case .newDirectory(_, let u): return u
    }
  }

  var needsCreate: Bool {
    if case .newDirectory = self { return true }
    return false
  }
}

@Observable
@MainActor
final class DirectoryPickerViewModel {
  /// Mirrors `SessionManagerViewModel.subtitlePenalty` so a clean basename
  /// hit outranks a path-scattered match.
  static let subtitlePenalty: Double = 0.6

  var query = ""
  private var allItems: [DirectoryPickerItem] = []
  var filteredItems: [DirectoryPickerItem] = []
  var selectedIndex = 0
  var matchResults: [String: ItemMatchResult] = [:]

  private let excludedURLs: Set<URL>
  private let frecencyService: FrecencyService

  init(
    excluding: [URL] = [],
    frecencyService: FrecencyService = FrecencyService()
  ) {
    self.excludedURLs = Set(excluding.map(\.standardizedFileURL))
    self.frecencyService = frecencyService
  }

  func load() async {
    let dirs = await ZoxideService.recentDirectories()
    let items: [DirectoryPickerItem] = dirs
      .filter { !excludedURLs.contains($0.standardizedFileURL) }
      .map { .directory($0) }

    allItems = items.sorted { a, b in
      let scoreA = a.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      let scoreB = b.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      return scoreA > scoreB
    }
    applyFilter()
  }

  func updateQuery(_ newQuery: String) {
    query = newQuery
    applyFilter()
  }

  func moveUp() { selectedIndex = max(0, selectedIndex - 1) }
  func moveDown() { selectedIndex = min(max(filteredItems.count - 1, 0), selectedIndex + 1) }

  func completionValue() -> String? {
    guard selectedIndex < filteredItems.count else { return nil }
    return filteredItems[selectedIndex].resolvedURL?.path
  }

  /// Returns the picked URL after recording frecency / creating the
  /// directory if needed. Returns nil when nothing is selectable.
  func confirmSelection() -> URL? {
    guard selectedIndex < filteredItems.count else { return nil }
    let item = filteredItems[selectedIndex]

    if let key = item.frecencyKey {
      frecencyService.recordAccess(for: key)
    }

    let fm = FileManager.default
    guard let url = item.resolvedURL else { return nil }

    if item.needsCreate {
      try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
      return nil
    }
    frecencyService.recordAccess(for: "dir:\(url.path)")
    return url
  }

  private func applyFilter() {
    matchResults = [:]
    let tokens = query.split(separator: " ").map(String.init)

    var items = allItems
    if let newItem = resolveNewOption(query: query) {
      items.insert(newItem, at: 0)
    }

    if tokens.isEmpty {
      filteredItems = items
      selectedIndex = 0
      return
    }

    struct Scored {
      let item: DirectoryPickerItem
      let result: ItemMatchResult
    }
    var scored: [Scored] = []

    for item in items {
      // Skip scoring the synthetic "Create + reparent" option; if it
      // resolved, the user typed a real path and wants it pinned at the top.
      if case .newDirectory = item {
        scored.append(
          Scored(
            item: item,
            result: ItemMatchResult(score: 1.0, displayNameIndices: [], subtitleIndices: []))
        )
        continue
      }
      let rawName = item.displayName
      let subtitle = item.subtitle

      var allMatch = true
      var minScore = Double.infinity
      var displayIndices: [Int] = []
      var subtitleIndices: [Int] = []

      for token in tokens {
        let displayMatch = FuzzyMatcher.match(query: token, target: rawName)
        let subtitleMatch = subtitle.flatMap { FuzzyMatcher.match(query: token, target: $0) }
        let subtitleScore = subtitleMatch.map { $0.score * Self.subtitlePenalty }

        if let dm = displayMatch, let sm = subtitleMatch, let ss = subtitleScore {
          if dm.score >= ss {
            minScore = min(minScore, dm.score)
            displayIndices.append(contentsOf: dm.matchedIndices)
          } else {
            minScore = min(minScore, ss)
            subtitleIndices.append(contentsOf: sm.matchedIndices)
          }
        } else if let dm = displayMatch {
          minScore = min(minScore, dm.score)
          displayIndices.append(contentsOf: dm.matchedIndices)
        } else if let sm = subtitleMatch, let ss = subtitleScore {
          minScore = min(minScore, ss)
          subtitleIndices.append(contentsOf: sm.matchedIndices)
        } else {
          allMatch = false
          break
        }
      }

      guard allMatch else { continue }
      scored.append(
        Scored(
          item: item,
          result: ItemMatchResult(
            score: minScore,
            displayNameIndices: displayIndices,
            subtitleIndices: subtitleIndices))
      )
    }

    scored.sort { a, b in
      if a.result.score != b.result.score { return a.result.score > b.result.score }
      let fa = a.item.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      let fb = b.item.frecencyKey.map { frecencyService.score(for: $0) } ?? 0
      return fa > fb
    }

    filteredItems = scored.map(\.item)
    for s in scored { matchResults[s.item.id] = s.result }
    selectedIndex = 0
  }

  /// Build a "Create + reparent to <dir>" entry from a path-like query.
  /// Mirrors `SessionManagerViewModel.resolveNewOption`'s path branch but
  /// only handles directories (no SSH, no plain-text "name" creation).
  private func resolveNewOption(query: String) -> DirectoryPickerItem? {
    guard !query.isEmpty else { return nil }
    guard query.contains("/") || query.hasPrefix("~") else { return nil }

    let expanded = (query as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded).standardized
    let fm = FileManager.default

    var isDir: ObjCBool = false
    if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
      // Existing directory → surface it as a regular hit (allItems
      // already sources from zoxide; this catches paths zoxide hasn't
      // indexed yet).
      return isDir.boolValue ? .directory(url) : nil
    }

    let parent = url.deletingLastPathComponent()
    var parentIsDir: ObjCBool = false
    if fm.fileExists(atPath: parent.path, isDirectory: &parentIsDir), parentIsDir.boolValue {
      return .newDirectory(query: query, url: url)
    }
    return nil
  }
}
