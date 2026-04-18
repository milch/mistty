import AppKit
import GhosttyKit
import MisttyShared

// MARK: - C Callbacks (top-level, no captures)

/// Called from a background thread when ghostty needs attention.
/// Must dispatch to main thread.
private let wakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
  guard let userdata else { return }
  let manager = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
  DispatchQueue.main.async {
    manager.tick()
  }
}

/// Called when ghostty wants the apprt to perform an action.
private let actionCallback: ghostty_runtime_action_cb = { app, target, action in
  switch action.tag {
  case GHOSTTY_ACTION_RENDER:
    return true

  case GHOSTTY_ACTION_SET_TITLE:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      if let title = action.action.set_title.title {
        let titleStr = String(cString: title)
        DispatchQueue.main.async {
          guard let userdata = ghostty_surface_userdata(surface) else { return }
          let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
          NotificationCenter.default.post(
            name: .ghosttySetTitle,
            object: nil,
            userInfo: ["paneID": view.pane?.id as Any, "title": titleStr]
          )
        }
      }
    }
    return true

  case GHOSTTY_ACTION_CLOSE_WINDOW:
    return true

  case GHOSTTY_ACTION_CELL_SIZE,
    GHOSTTY_ACTION_SIZE_LIMIT,
    GHOSTTY_ACTION_INITIAL_SIZE,
    GHOSTTY_ACTION_MOUSE_SHAPE,
    GHOSTTY_ACTION_MOUSE_VISIBILITY:
    return true

  case GHOSTTY_ACTION_RING_BELL:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      DispatchQueue.main.async {
        guard let userdata = ghostty_surface_userdata(surface) else { return }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        NotificationCenter.default.post(
          name: .ghosttyRingBell,
          object: nil,
          userInfo: ["paneID": view.pane?.id as Any]
        )
      }
    }
    return true

  case GHOSTTY_ACTION_SCROLLBAR:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      let sb = action.action.scrollbar
      DispatchQueue.main.async {
        guard let userdata = ghostty_surface_userdata(surface) else { return }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        view.scrollbarState = ScrollbarState(total: sb.total, offset: sb.offset, len: sb.len)
        // If copy mode is hinting, re-scan labels after mouse/wheel scroll.
        NotificationCenter.default.post(name: .misttyScrollChanged, object: nil)
      }
    }
    return true

  default:
    return false
  }
}

/// Clipboard read callback (stub).
private let readClipboardCallback: ghostty_runtime_read_clipboard_cb = {
  userdata, clipboard, state in
  guard let state else { return false }
  let pasteboard = NSPasteboard.general
  if let str = pasteboard.string(forType: .string) {
    str.withCString { ptr in
      // TODO: complete clipboard read
    }
  }
  return false
}

/// Clipboard confirm read callback (stub).
private let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = {
  userdata, str, state, request in
  guard let state else { return }
}

/// Clipboard write callback.
private let writeClipboardCallback: ghostty_runtime_write_clipboard_cb = {
  userdata, clipboard, content, count, confirm in
  guard let content, count > 0 else { return }
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()
  if let data = content.pointee.data {
    pasteboard.setString(String(cString: data), forType: .string)
  }
}

/// Close surface callback — shell exited.
private let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { userdata, processAlive in
  guard let userdata else { return }
  let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  DispatchQueue.main.async {
    NotificationCenter.default.post(
      name: .ghosttyCloseSurface,
      object: nil,
      userInfo: ["paneID": view.pane?.id as Any]
    )
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let ghosttySetTitle = Notification.Name("ghosttySetTitle")
  static let ghosttyCloseSurface = Notification.Name("ghosttyCloseSurface")
  static let ghosttyRingBell = Notification.Name("ghosttyRingBell")
}

// MARK: - GhosttyAppManager

@MainActor
final class GhosttyAppManager {
  static let shared = GhosttyAppManager()

  nonisolated(unsafe) private(set) var app: ghostty_app_t?
  nonisolated(unsafe) private var config: ghostty_config_t?

  /// Retains the KVO subscription that pushes macOS appearance changes to
  /// ghostty. Without this, ghostty never learns the system is dark/light —
  /// our `window-theme = system` default has nothing to resolve against, so
  /// themes like `"light:X,dark:Y"` always fall back to the light variant.
  private var appearanceObserver: NSKeyValueObservation?

  private init() {
    // 1. Initialize ghostty
    let initResult = ghostty_init(0, nil)
    guard initResult == GHOSTTY_SUCCESS else {
      print("[GhosttyAppManager] ghostty_init failed: \(initResult)")
      return
    }

    // 2. Create and load config
    guard let cfg = ghostty_config_new() else {
      print("[GhosttyAppManager] ghostty_config_new failed")
      return
    }

    // Load Mistty's own ghostty config (always separate from Ghostty.app config)
    let misttyConfigPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/mistty/ghostty.conf").path
    if FileManager.default.fileExists(atPath: misttyConfigPath) {
      misttyConfigPath.withCString { path in
        ghostty_config_load_file(cfg, path)
      }
    }

    // Apply Mistty-managed ghostty settings (top-level font/cursor, the
    // [ghostty] passthrough table, and [ui] padding) by writing a temp
    // ghostty config file and loading it after the user's file, so these
    // keys override whatever was in ~/.config/mistty/ghostty.conf.
    let misttyConfig: MisttyConfig
    do {
      misttyConfig = try MisttyConfig.loadThrowing()
    } catch {
      misttyConfig = .default
      // Surface parse errors to the user so they know why Mistty launched
      // with defaults instead of their config. Scheduled on main after the
      // app finishes launching so the alert isn't eaten.
      let message = describeTOMLParseError(error)
      DispatchQueue.main.async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mistty could not parse config.toml"
        alert.informativeText =
          "Falling back to defaults.\n\n\(message)\n\nFile: \(MisttyConfig.configURL.path)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
      }
    }

    let ghosttyLines = misttyConfig.ghosttyConfigLines
    print("[mistty] resolved ghostty config:")
    if ghosttyLines.isEmpty {
      print("  (no Mistty-managed keys — using ghostty defaults + ~/.config/mistty/ghostty.conf)")
    } else {
      for line in ghosttyLines { print("  \(line)") }
    }

    if !ghosttyLines.isEmpty {
      let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mistty-ghostty-\(ProcessInfo.processInfo.processIdentifier).conf")
      let contents = ghosttyLines.joined(separator: "\n") + "\n"
      if (try? contents.write(to: tempURL, atomically: true, encoding: .utf8)) != nil {
        tempURL.path.withCString { path in
          ghostty_config_load_file(cfg, path)
        }
      }
    }

    ghostty_config_finalize(cfg)
    self.config = cfg

    // Log any config diagnostics
    let diagCount = ghostty_config_diagnostics_count(cfg)
    for i in 0..<diagCount {
      let diag = ghostty_config_get_diagnostic(cfg, i)
      if let msg = diag.message {
        print("[GhosttyAppManager] config diagnostic: \(String(cString: msg))")
      }
    }

    // 3. Build runtime config with C callbacks
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var runtimeCfg = ghostty_runtime_config_s(
      userdata: selfPtr,
      supports_selection_clipboard: false,
      wakeup_cb: wakeupCallback,
      action_cb: actionCallback,
      read_clipboard_cb: readClipboardCallback,
      confirm_read_clipboard_cb: confirmReadClipboardCallback,
      write_clipboard_cb: writeClipboardCallback,
      close_surface_cb: closeSurfaceCallback
    )

    // 4. Create the app
    self.app = ghostty_app_new(&runtimeCfg, cfg)
    if self.app == nil {
      print("[GhosttyAppManager] ghostty_app_new failed")
    }

    // 5. Push the current (and future) macOS appearance to ghostty. `.initial`
    // fires synchronously so the first surface already sees the right scheme.
    self.appearanceObserver = NSApplication.shared.observe(
      \.effectiveAppearance,
      options: [.new, .initial]
    ) { [weak self] _, change in
      guard let self, let app = self.app else { return }
      guard let appearance = change.newValue else { return }
      let scheme: ghostty_color_scheme_e =
        appearance.name.rawValue.lowercased().contains("dark")
          ? GHOSTTY_COLOR_SCHEME_DARK
          : GHOSTTY_COLOR_SCHEME_LIGHT
      ghostty_app_set_color_scheme(app, scheme)
    }
  }

  deinit {
    if let app { ghostty_app_free(app) }
    if let config { ghostty_config_free(config) }
  }

  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }
}
