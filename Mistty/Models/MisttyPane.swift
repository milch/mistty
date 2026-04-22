import AppKit
import Foundation

@Observable
@MainActor
final class MisttyPane: Identifiable {
  let id: Int
  /// Directory passed to ghostty at surface creation. Doesn't track `cd`s.
  var directory: URL?
  /// Live CWD reported via OSC 7 / ghostty's `GHOSTTY_ACTION_PWD`. `nil` until
  /// the shell emits its first PWD report. Used by split/new-tab to inherit
  /// the focused pane's current location instead of the initial session dir.
  var currentWorkingDirectory: URL?
  var command: String?
  /// When true, use ghostty's command field (which forces wait-after-command).
  /// When false, send the command as initial input so the shell exits naturally.
  var useCommandField: Bool = true

  var processTitle: String?

  var isRunningNeovim: Bool {
    guard let title = processTitle?.lowercased() else { return false }
    let neovimNames = ["nvim", "neovim", "vim"]
    return neovimNames.contains(where: { title == $0 || title.hasPrefix($0 + " ") })
  }

  init(id: Int) {
    self.id = id
  }

  /// The persistent terminal surface view for this pane.
  /// Created lazily on first access so the ghostty surface lives
  /// for the lifetime of the pane, surviving SwiftUI view rebuilds.
  @ObservationIgnored
  lazy var surfaceView: TerminalSurfaceView = {
    let view = TerminalSurfaceView(
      frame: .zero,
      workingDirectory: directory,
      command: useCommandField ? command : nil,
      initialInput: useCommandField ? nil : command
    )
    view.pane = self
    return view
  }()

  /// Route keyboard input to this pane's surface. Safe to call on the
  /// next runloop tick so the view has a chance to be hosted in a window
  /// (e.g. after a tab switch).
  func focusKeyboardInput() {
    DispatchQueue.main.async { [surfaceView] in
      surfaceView.window?.makeFirstResponder(surfaceView)
    }
  }
}
