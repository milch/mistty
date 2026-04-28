import Foundation

public struct WorkspaceSnapshot: Codable, Sendable {
  public static let currentVersion = 2

  public let version: Int
  public let windows: [WindowSnapshot]
  public let activeWindowID: Int?

  /// Set when decoding a payload whose version is neither 1 (migrated) nor
  /// the current version. Callers bail to empty state with a log line.
  public var unsupportedVersion: Int?

  public init(version: Int, windows: [WindowSnapshot], activeWindowID: Int?) {
    self.version = version
    self.windows = windows
    self.activeWindowID = activeWindowID
    self.unsupportedVersion = nil
  }

  // MARK: - Codable with v1 migration

  enum CodingKeys: String, CodingKey {
    case version
    case windows
    case activeWindowID
    // v1 fields (read-only during migration)
    case sessions
    case activeSessionID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try container.decode(Int.self, forKey: .version)

    if decodedVersion == 2 {
      self.version = 2
      self.windows = try container.decode([WindowSnapshot].self, forKey: .windows)
      self.activeWindowID = try container.decodeIfPresent(Int.self, forKey: .activeWindowID)
      self.unsupportedVersion = nil
    } else if decodedVersion == 1 {
      // Migrate: the v1 payload's flat sessions become a single synthetic
      // window with id=1. nextWindowID will be bumped past 1 by
      // advanceIDCounters during restore.
      let v1Sessions = try container.decode([SessionSnapshot].self, forKey: .sessions)
      let v1ActiveSessionID = try container.decodeIfPresent(Int.self, forKey: .activeSessionID)
      self.version = WorkspaceSnapshot.currentVersion
      self.windows = [
        WindowSnapshot(id: 1, sessions: v1Sessions, activeSessionID: v1ActiveSessionID)
      ]
      self.activeWindowID = 1
      self.unsupportedVersion = nil
    } else {
      // Future / unknown version. Mark unsupported and let the caller bail.
      self.version = decodedVersion
      self.windows = []
      self.activeWindowID = nil
      self.unsupportedVersion = decodedVersion
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(windows, forKey: .windows)
    try container.encodeIfPresent(activeWindowID, forKey: .activeWindowID)
  }
}
