import Foundation

public struct SessionSnapshot: Codable, Sendable, Equatable {
  /// Stable identity; set once at snapshot time and never mutated.
  public let id: Int
  /// Internal session name. Distinct from customName, which users edit.
  public var name: String
  /// User-set display name override. nil ⇒ fall back to name.
  public var customName: String?
  /// Directory the session was created in. Panes may have drifted via OSC 7.
  public var directory: URL
  /// SSH command for SSH-type sessions. nil for local sessions.
  public var sshCommand: String?
  /// Used by the session manager's running-sessions LRU sort.
  public var lastActivatedAt: Date
  /// Tabs in sidebar order.
  public var tabs: [TabSnapshot]
  /// Tab that had focus when the snapshot was taken. nil ⇒ first available.
  public var activeTabID: Int?

  public init(
    id: Int,
    name: String,
    customName: String? = nil,
    directory: URL,
    sshCommand: String? = nil,
    lastActivatedAt: Date,
    tabs: [TabSnapshot],
    activeTabID: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.customName = customName
    self.directory = directory
    self.sshCommand = sshCommand
    self.lastActivatedAt = lastActivatedAt
    self.tabs = tabs
    self.activeTabID = activeTabID
  }
}
