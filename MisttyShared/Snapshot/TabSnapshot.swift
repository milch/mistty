import Foundation

public struct TabSnapshot: Codable, Sendable, Equatable {
  /// Stable identity; set once at snapshot time and never mutated.
  public let id: Int
  /// User-set title override. nil ⇒ title follows the running process via OSC 2.
  public var customTitle: String?
  /// Tab's initial directory. Not tracked after creation.
  public var directory: URL?
  /// Root of the pane split tree for this tab.
  public var layout: LayoutNodeSnapshot
  /// Pane that had focus when the snapshot was taken. nil ⇒ first available.
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
