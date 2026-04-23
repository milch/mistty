import Foundation

public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
  /// Current schema version. The decoder records an unsupported version
  /// in `unsupportedVersion` instead of throwing; callers inspect that
  /// field and decide whether to bail or migrate.
  public static let currentVersion = 1

  /// Schema version as written to disk. Compare against `currentVersion` via `unsupportedVersion`.
  public var version: Int
  /// Sessions in sidebar order.
  public var sessions: [SessionSnapshot]
  /// Session that had focus when the snapshot was taken. nil ⇒ first available.
  public var activeSessionID: Int?

  /// Non-nil when the decoded `version` field isn't understood by this
  /// build. Callers should treat non-nil as "bail, start empty."
  public var unsupportedVersion: Int? {
    version == Self.currentVersion ? nil : version
  }

  public init(
    version: Int = WorkspaceSnapshot.currentVersion,
    sessions: [SessionSnapshot] = [],
    activeSessionID: Int? = nil
  ) {
    self.version = version
    self.sessions = sessions
    self.activeSessionID = activeSessionID
  }
}
