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
  /// When true, use ghostty's `cfg.command` (exec via `/bin/sh -c`).
  /// When false, send the command as `cfg.initial_input` so a login shell
  /// runs it — used by SSH panes where the shell must stay alive after
  /// the command exits.
  var useCommandField: Bool = true
  /// Only meaningful when `useCommandField == true`. False makes the pane
  /// close as soon as the ghostty-spawned command exits (popup close-on-exit);
  /// true keeps it around until the user hits a key (the default ghostty UX).
  /// Requires the Mistty patch to `vendor/ghostty/src/apprt/embedded.zig`
  /// that stops forcing wait-after-command when a command is given.
  var waitAfterCommand: Bool = true

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
      initialInput: useCommandField ? nil : command,
      waitAfterCommand: waitAfterCommand
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
