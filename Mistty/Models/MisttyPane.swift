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
  /// When true, the pane stays open after its process exits and shows
  /// "press any key to close". When false (default, matching ghostty's own
  /// default), the pane closes as soon as the process exits — so typing
  /// `exit` in a regular shell pane closes it like you'd expect. Popups
  /// that want to linger (`close_on_exit = false`) flip this to true.
  ///
  /// Relies on the Mistty libghostty patch that stops unconditionally
  /// forcing `wait-after-command = true` whenever `cfg.command` is set.
  var waitAfterCommand: Bool = false

  var processTitle: String?

  /// Process ID of the shell (or the command passed via `cfg.command`) that
  /// libghostty spawned for this pane. `-1` when the surface hasn't started
  /// yet, has exited, or libghostty wasn't built with the shell-PID patch.
  /// Reads without forcing surface allocation.
  var shellPID: pid_t {
    surfaceViewIfLoaded?.shellPID ?? -1
  }

  /// Master fd of the pty pair. Use with `tcgetpgrp()` to resolve the
  /// foreground process group on the tty. `-1` when unavailable.
  var ptyFD: Int32 {
    surfaceViewIfLoaded?.ptyFD ?? -1
  }

  var isRunningNeovim: Bool {
    guard let title = processTitle?.lowercased() else { return false }
    let neovimNames = ["nvim", "neovim", "vim"]
    return neovimNames.contains(where: { title == $0 || title.hasPrefix($0 + " ") })
  }

  init(id: Int) {
    self.id = id
  }

  /// Backing storage. `nil` until something reads `surfaceView` for the
  /// first time. Read via `surfaceViewIfLoaded` when you need to peek
  /// without forcing allocation.
  @ObservationIgnored
  private var _surfaceView: TerminalSurfaceView?

  /// The persistent terminal surface view for this pane. Created on first
  /// access so the ghostty surface lives for the lifetime of the pane,
  /// surviving SwiftUI view rebuilds.
  var surfaceView: TerminalSurfaceView {
    if let existing = _surfaceView { return existing }
    let view = TerminalSurfaceView(
      frame: .zero,
      workingDirectory: directory,
      command: useCommandField ? command : nil,
      initialInput: useCommandField ? nil : command,
      waitAfterCommand: waitAfterCommand
    )
    view.pane = self
    _surfaceView = view
    return view
  }

  /// Peek at the surface view without forcing creation. Returns nil if
  /// nothing has called `surfaceView` yet.
  var surfaceViewIfLoaded: TerminalSurfaceView? { _surfaceView }

  /// Route keyboard input to this pane's surface. Safe to call on the
  /// next runloop tick so the view has a chance to be hosted in a window
  /// (e.g. after a tab switch).
  func focusKeyboardInput() {
    DispatchQueue.main.async { [surfaceView] in
      surfaceView.window?.makeFirstResponder(surfaceView)
    }
  }
}
