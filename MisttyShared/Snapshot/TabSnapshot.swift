import Foundation

public struct TabSnapshot: Codable, Sendable, Equatable {
  public let id: Int
  public var customTitle: String?
  public var directory: URL?
  public var layout: LayoutNodeSnapshot
  public var activePaneID: Int?

  public init(
    id: Int,
    customTitle: String? = nil,
    directory: URL? = nil,
    layout: LayoutNodeSnapshot,
    activePaneID: Int? = nil
  ) {
    self.id = id
    self.customTitle = customTitle
    self.directory = directory
    self.layout = layout
    self.activePaneID = activePaneID
  }
}
