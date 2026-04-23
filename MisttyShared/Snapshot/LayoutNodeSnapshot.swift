import Foundation

public enum SplitDirectionSnapshot: String, Codable, Sendable {
  case horizontal
  case vertical
}

public struct PaneSnapshot: Codable, Sendable, Equatable {
  public let id: Int
  /// Initial directory used when the pane was originally created.
  public var directory: URL?
  /// Live OSC 7 CWD at save time. Used as the spawn directory on restore.
  public var currentWorkingDirectory: URL?
  /// Captured foreground process. `nil` ⇒ bare shell on restore.
  public var captured: CapturedProcess?

  public init(
    id: Int,
    directory: URL? = nil,
    currentWorkingDirectory: URL? = nil,
    captured: CapturedProcess? = nil
  ) {
    self.id = id
    self.directory = directory
    self.currentWorkingDirectory = currentWorkingDirectory
    self.captured = captured
  }
}

public indirect enum LayoutNodeSnapshot: Codable, Sendable, Equatable {
  case leaf(pane: PaneSnapshot)
  case split(
    direction: SplitDirectionSnapshot,
    a: LayoutNodeSnapshot,
    b: LayoutNodeSnapshot,
    ratio: Double
  )
}
