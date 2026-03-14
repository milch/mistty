import Foundation

struct FrecencyEntry: Codable {
  var frequency: Int
  var lastAccessed: Date
}

@MainActor
final class FrecencyService {
  private var entries: [String: FrecencyEntry] = [:]
  private let storageURL: URL

  init(storageURL: URL? = nil) {
    self.storageURL = storageURL ?? Self.defaultStorageURL()
    load()
  }

  private static func defaultStorageURL() -> URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    let dir = appSupport.appendingPathComponent("com.mistty")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("frecency.json")
  }

  func score(for key: String) -> Double {
    guard let entry = entries[key] else { return 0 }
    let hoursSinceAccess = -entry.lastAccessed.timeIntervalSinceNow / 3600
    let recencyWeight: Double
    switch hoursSinceAccess {
    case ..<1: recencyWeight = 4.0
    case ..<24: recencyWeight = 2.0
    case ..<168: recencyWeight = 1.0
    default: recencyWeight = 0.5
    }
    return Double(entry.frequency) * recencyWeight
  }

  func recordAccess(for key: String) {
    var entry = entries[key] ?? FrecencyEntry(frequency: 0, lastAccessed: Date())
    entry.frequency += 1
    entry.lastAccessed = Date()
    entries[key] = entry
    save()
  }

  func setLastAccessed(for key: String, date: Date) {
    guard var entry = entries[key] else { return }
    entry.lastAccessed = date
    entries[key] = entry
    save()
  }

  private func load() {
    guard let data = try? Data(contentsOf: storageURL),
      let decoded = try? JSONDecoder().decode([String: FrecencyEntry].self, from: data)
    else { return }
    entries = decoded
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: storageURL, options: .atomic)
  }
}
