import Foundation

public struct SessionSnapshot: Codable, Sendable, Equatable {
  public let id: Int
  public var name: String
  public var customName: String?
  public var directory: URL
  public var sshCommand: String?
  public var lastActivatedAt: Date
  public var tabs: [TabSnapshot]
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
