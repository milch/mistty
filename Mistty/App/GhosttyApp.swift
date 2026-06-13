import AppKit
import GhosttyKit
import MisttyShared

// MARK: - C Callbacks (top-level, no captures)

/// Stashed so the C action callback can push our config back through
/// `ghostty_app_update_config` without reaching into the main-actor-isolated
/// `GhosttyAppManager.shared`. Written once during manager init.
nonisolated(unsafe) private var sharedGhosttyConfig: ghostty_config_t?

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
        // Resolve userdata NOW — `surface` is only guaranteed valid for
        // the duration of this callback. The main thread can free it
        // (tearDownSurface) before the async block runs, which made the
        // deferred ghostty_surface_userdata call a use-after-free. The
        // retain keeps the Swift view alive across the hop; the C
        // surface pointer is never touched after this callback returns.
        guard let userdata = ghostty_surface_userdata(surface) else { return true }
        let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
        DispatchQueue.main.async {
          let view = unmanagedView.takeRetainedValue()
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
      // See GHOSTTY_ACTION_SET_TITLE for the userdata-resolution rationale.
      guard let userdata = ghostty_surface_userdata(surface) else { return true }
      let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
      DispatchQueue.main.async {
        let view = unmanagedView.takeRetainedValue()
        NotificationCenter.default.post(
          name: .ghosttyRingBell,
          object: nil,
          userInfo: ["paneID": view.pane?.id as Any]
        )
      }
    }
    return true

  case GHOSTTY_ACTION_PWD:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      if let pwd = action.action.pwd.pwd {
        let pwdStr = String(cString: pwd)
        // See GHOSTTY_ACTION_SET_TITLE for the userdata-resolution rationale.
        guard let userdata = ghostty_surface_userdata(surface) else { return true }
        let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
        DispatchQueue.main.async {
          let view = unmanagedView.takeRetainedValue()
          NotificationCenter.default.post(
            name: .ghosttyPwd,
            object: nil,
            userInfo: ["paneID": view.pane?.id as Any, "pwd": pwdStr]
          )
        }
      }
    }
    return true

  case GHOSTTY_ACTION_SCROLLBAR:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      let sb = action.action.scrollbar
      // See GHOSTTY_ACTION_SET_TITLE for the userdata-resolution rationale.
      guard let userdata = ghostty_surface_userdata(surface) else { return true }
      let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
      DispatchQueue.main.async {
        let view = unmanagedView.takeRetainedValue()
        view.scrollbarState = ScrollbarState(total: sb.total, offset: sb.offset, len: sb.len)
        // This action fires for every output chunk (thousands/sec during a
        // fast build) and was broadcast app-wide. Its only consumer is the
        // copy-mode hint rescan, which no-ops unless the pane is hinting —
        // so skip the post unless the emitting pane is actually hinting.
        if view.pane?.copyModeState?.isHinting == true {
          NotificationCenter.default.post(name: .misttyScrollChanged, object: nil)
        }
      }
    }
    return true

  case GHOSTTY_ACTION_RELOAD_CONFIG:
    // `ghostty_app_set_color_scheme` bumps `core_app.config_conditional_state`
    // and fires `reload_config(.soft)` so the apprt can push the new state
    // into `app.config._conditional_state`. Without that sync, the next
    // `ghostty_surface_new` sees a state mismatch and ghostty's `Surface.init`
    // rebuilds the config via `changeConditionalState` — which replays the
    // config load steps and DROPS the per-surface `cfg.initial_input` /
    // `cfg.command` we set for popups, so the shell spawns empty.
    // Mirror ghostty's own macOS apprt: on soft reload, push our existing
    // config back through `ghostty_app_update_config`.
    if action.action.reload_config.soft, let cfg = sharedGhosttyConfig {
      ghostty_app_update_config(app, cfg)
    }
    return true

  case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
    if target.tag == GHOSTTY_TARGET_SURFACE {
      let surface = target.target.surface
      let notification = action.action.desktop_notification
      // Convert the C strings synchronously — `action` is only valid for the
      // duration of this callback.
      let title = notification.title.map { String(cString: $0) } ?? ""
      let body = notification.body.map { String(cString: $0) } ?? ""
      // See GHOSTTY_ACTION_SET_TITLE for the userdata-resolution rationale.
      guard let userdata = ghostty_surface_userdata(surface) else { return true }
      let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
      DispatchQueue.main.async {
        let view = unmanagedView.takeRetainedValue()
        NotificationCenter.default.post(
          name: .ghosttyDesktopNotification,
          object: nil,
          userInfo: ["paneID": view.pane?.id as Any, "title": title, "body": body]
        )
      }
    }
    return true

  default:
    return false
  }
}

/// Clipboard read callback — libghostty invokes this for `paste_from_clipboard`
/// (default Cmd+V) and for OSC-52 reads issued from inside the terminal. We
/// hand the pasteboard contents back via `ghostty_surface_complete_clipboard_request`;
/// if ghostty decides the paste is unsafe it'll route back through
/// `confirm_read_clipboard_cb` with the same `state` pointer.
private let readClipboardCallback: ghostty_runtime_read_clipboard_cb = {
  userdata, clipboard, state in
  guard let userdata, let state else { return false }
  let pasteboard = NSPasteboard.general
  guard let str = pasteboard.string(forType: .string), !str.isEmpty else { return false }
  let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  guard let surface = view.surface else { return false }
  str.withCString { ptr in
    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
  }
  return true
}

/// Clipboard confirm-read callback — ghostty routes a clipboard read here
/// when it needs confirmation: unsafe paste contents, or any OSC-52 read
/// (the default `clipboard-read = ask`). Cmd+V pastes are user-initiated,
/// so they auto-confirm (no prompt UI yet). OSC-52 reads are
/// program-initiated: auto-confirming them hands the user's clipboard
/// (passwords, tokens) to whatever runs in the pane, silently — so they
/// are denied. Denial completes the request with an empty string +
/// confirmed=true, matching ghostty's own cancel path
/// (BaseTerminalController.clipboardConfirmationComplete), which frees
/// the core's request state.
private let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = {
  userdata, str, state, request in
  guard let userdata, let state, let str else { return }
  let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  guard let surface = view.surface else { return }
  switch request {
  case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
    ghostty_surface_complete_clipboard_request(surface, str, state, true)
  default:
    // OSC-52 read (and any future program-initiated request): deny.
    ghostty_surface_complete_clipboard_request(surface, "", state, true)
  }
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

/// Close surface callback — shell exited. Retain the view across the
/// main-thread hop; the unretained reference could dangle if the pane is
/// torn down (and the view deallocated) before the block runs.
private let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { userdata, processAlive in
  guard let userdata else { return }
  let unmanagedView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).retain()
  DispatchQueue.main.async {
    let view = unmanagedView.takeRetainedValue()
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
  static let ghosttyPwd = Notification.Name("ghosttyPwd")
  static let ghosttyDesktopNotification = Notification.Name("ghosttyDesktopNotification")
}

// MARK: - GhosttyAppManager

@MainActor
final class GhosttyAppManager {
  static let shared = GhosttyAppManager()

  nonisolated(unsafe) private(set) var app: ghostty_app_t?
  nonisolated(unsafe) private var config: ghostty_config_t?

  /// Configs from prior reloads. We don't free these synchronously after
  /// `ghostty_app_update_config` because surface message processing may
  /// still hold references. Freed in `deinit`.
  nonisolated(unsafe) private var retiredConfigs: [ghostty_config_t] = []

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

    // 2. Build initial config
    let misttyConfig = MisttyConfig.current
    if let parseError = MisttyConfig.lastParseError {
      let message = describeTOMLParseError(parseError)
      // Defer the alert to the next runloop tick. By then NSApp is set up
      // (it isn't yet during MisttyApp.init, which is what runs GhosttyAppManager.shared).
      // Whether or not the app has fully finished launching at that point,
      // NSApp.activate + NSAlert.runModal both work — the alert blocks the
      // main thread modally; once the user dismisses it, launch continues.
      DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mistty could not parse config.toml"
        alert.informativeText =
          "Falling back to defaults.\n\n\(message)\n\nFile: \(MisttyConfig.configURL.path)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
      }
    }

    guard let cfg = buildGhosttyConfig(from: misttyConfig) else { return }
    self.config = cfg
    sharedGhosttyConfig = cfg

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

    // Re-push the ghostty config when MisttyConfig.reload() runs.
    NotificationCenter.default.addObserver(
      forName: .misttyConfigDidReload,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reloadConfig()
      }
    }
  }

  deinit {
    if let app { ghostty_app_free(app) }
    if let config { ghostty_config_free(config) }
    for cfg in retiredConfigs { ghostty_config_free(cfg) }
  }

  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  /// Build a fresh `ghostty_config_t` from the current `MisttyConfig`,
  /// loading `~/.config/mistty/ghostty.conf` first and then applying our
  /// resolved overrides via a temp file. Caller is responsible for the
  /// returned config's lifetime — pass to `ghostty_app_update_config` and
  /// retain until the next reload (or app shutdown).
  private func buildGhosttyConfig(from misttyConfig: MisttyConfig) -> ghostty_config_t? {
    guard let cfg = ghostty_config_new() else {
      print("[GhosttyAppManager] ghostty_config_new failed")
      return nil
    }

    let misttyConfigPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/mistty/ghostty.conf").path
    if FileManager.default.fileExists(atPath: misttyConfigPath) {
      misttyConfigPath.withCString { path in
        ghostty_config_load_file(cfg, path)
      }
    }

    let ghosttyLines = misttyConfig.ghosttyConfigLines
    if !ghosttyLines.isEmpty {
      let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "mistty-ghostty-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).conf")
      let contents = ghosttyLines.joined(separator: "\n") + "\n"
      if (try? contents.write(to: tempURL, atomically: true, encoding: .utf8)) != nil {
        tempURL.path.withCString { path in
          ghostty_config_load_file(cfg, path)
        }
      }
    }

    ghostty_config_finalize(cfg)
    return cfg
  }

  /// Re-parse the user's `~/.config/mistty/ghostty.conf` + the resolved
  /// passthrough lines and push the new config to ghostty. The previous
  /// `ghostty_config_t` is retired and freed on app shutdown.
  func reloadConfig() {
    guard let app = self.app else { return }
    guard let newCfg = buildGhosttyConfig(from: MisttyConfig.current) else { return }

    if let old = self.config {
      retiredConfigs.append(old)
    }
    self.config = newCfg
    sharedGhosttyConfig = newCfg
    ghostty_app_update_config(app, newCfg)

    let diagCount = ghostty_config_diagnostics_count(newCfg)
    for i in 0..<diagCount {
      let diag = ghostty_config_get_diagnostic(newCfg, i)
      if let msg = diag.message {
        print("[GhosttyAppManager] reload diagnostic: \(String(cString: msg))")
      }
    }
  }
}
