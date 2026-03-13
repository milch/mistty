import AppKit
import Foundation

@Observable
@MainActor
final class MisttyPane: Identifiable {
  let id: Int
  var directory: URL?
  var command: String?

  init(id: Int) {
    self.id = id
  }

  /// The persistent terminal surface view for this pane.
  /// Created lazily on first access so the ghostty surface lives
  /// for the lifetime of the pane, surviving SwiftUI view rebuilds.
  @ObservationIgnored
  lazy var surfaceView: TerminalSurfaceView = {
    let view = TerminalSurfaceView(frame: .zero, workingDirectory: directory, command: command)
    view.pane = self
    return view
  }()
}
