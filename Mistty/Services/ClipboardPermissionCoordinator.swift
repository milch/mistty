import AppKit
import GhosttyKit

/// Owns OSC-52 clipboard-read permission decisions: in-memory session
/// overrides, resolution against config + the pure `ClipboardPermission` core,
/// the prompt sheet, and persistence of "always" choices. Reachable from the
/// libghostty callback via `.shared`, configured with the WindowsStore at app
/// start (same pattern as NotificationService.shared.start).
@MainActor
final class ClipboardPermissionCoordinator {
  static let shared = ClipboardPermissionCoordinator()

  /// The five prompt outcomes.
  enum Choice {
    case allowOnce, allowAlways, allowSession, denyOnce, denyAlways
  }

  /// Result of applying a choice: whether to allow this request, plus an
  /// optional per-process rule the caller should persist (for "always"
  /// choices). Returning the rule instead of stashing it keeps `applyChoice`
  /// free of hidden state and disk I/O, so it stays unit-testable.
  struct ChoiceResult: Equatable {
    let allowed: Bool
    let persist: ClipboardProcessRule?
  }

  private weak var windowsStore: WindowsStore?

  /// In-memory, session-scoped overrides keyed by "<sessionID>\u{0}<exe>".
  private var sessionOverrides: [String: ClipboardReadMode] = [:]

  init() {}

  /// Wire up the store (called once from MisttyApp.init).
  func start(windowsStore: WindowsStore) {
    self.windowsStore = windowsStore
  }

  private func key(_ sessionID: Int, _ executable: String) -> String {
    "\(sessionID)\u{0}\(executable)"
  }

  // MARK: - Session overrides

  func setSessionOverride(_ mode: ClipboardReadMode, executable: String, sessionID: Int) {
    sessionOverrides[key(sessionID, executable)] = mode
  }

  func sessionOverride(executable: String, sessionID: Int) -> ClipboardReadMode? {
    sessionOverrides[key(sessionID, executable)]
  }

  /// Drop all overrides for a session (called when the session closes).
  func clearSession(_ sessionID: Int) {
    let prefix = "\(sessionID)\u{0}"
    sessionOverrides = sessionOverrides.filter { !$0.key.hasPrefix(prefix) }
  }

  // MARK: - Decision

  /// Resolve the effective mode for `executable` in `sessionID` against the
  /// given config and current session overrides.
  func decision(
    forExecutable executable: String, sessionID: Int, config: MisttyConfig
  ) -> ClipboardReadMode {
    ClipboardPermission.resolve(
      global: config.clipboardRead,
      processRule: config.clipboardProcessRule(for: executable),
      sessionOverride: sessionOverride(executable: executable, sessionID: sessionID))
  }

  // MARK: - Prompt choices

  /// Apply a prompt outcome: set a session override when needed and report
  /// whether to allow this request plus any per-process rule to persist.
  @discardableResult
  func applyChoice(_ choice: Choice, executable: String, sessionID: Int) -> ChoiceResult {
    switch choice {
    case .allowOnce:
      return ChoiceResult(allowed: true, persist: nil)
    case .denyOnce:
      return ChoiceResult(allowed: false, persist: nil)
    case .allowSession:
      setSessionOverride(.allow, executable: executable, sessionID: sessionID)
      return ChoiceResult(allowed: true, persist: nil)
    case .allowAlways:
      return ChoiceResult(
        allowed: true, persist: ClipboardProcessRule(name: executable, mode: .allow))
    case .denyAlways:
      return ChoiceResult(
        allowed: false, persist: ClipboardProcessRule(name: executable, mode: .deny))
    }
  }

  /// Persist a per-process rule to config: update `MisttyConfig.current`, save
  /// to disk, and post `.misttyConfigDidReload` so ConfigStore stays in sync.
  /// Save failures are logged, not fatal — the in-memory decision still applied.
  func persist(_ rule: ClipboardProcessRule) {
    let updated = MisttyConfig.current.settingClipboardProcessRule(
      name: rule.name, mode: rule.mode)
    MisttyConfig.current = updated
    do {
      try updated.save()
    } catch {
      DebugLog.shared.log("clipboard", "failed to persist process rule: \(error)")
    }
    NotificationCenter.default.post(name: .misttyConfigDidReload, object: nil)
  }

  // MARK: - libghostty entry

  /// Decide an OSC-52 read request and complete it. Called on the main actor
  /// from the clipboard callback. `executable` is the foreground process name
  /// resolved *synchronously* by the caller at read time (nil = plain shell
  /// prompt → keyed as "(unknown)"); resolving it post-hop would mis-attribute
  /// the read to shell-integration helpers. `content` is the clipboard text
  /// already read by libghostty; `state` belongs to the open request. The
  /// `view` is held (not the raw surface) so completion can re-fetch a *live*
  /// surface — a deferred prompt may outlive the pane.
  func decide(
    view: TerminalSurfaceView, executable: String?,
    state: UnsafeMutableRawPointer, content: String
  ) {
    guard let paneID = view.pane?.id,
      let resolved = windowsStore?.pane(byId: paneID)
    else {
      complete(view: view, state: state, allow: false, content: content)
      return
    }
    let executable = executable ?? "(unknown)"
    let sessionID = resolved.session.id

    switch decision(
      forExecutable: executable, sessionID: sessionID, config: MisttyConfig.current)
    {
    case .allow:
      complete(view: view, state: state, allow: true, content: content)
    case .deny:
      complete(view: view, state: state, allow: false, content: content)
    case .prompt:
      let window = windowsStore?.trackedNSWindow(byId: resolved.window.id)?.window
      guard let window else {
        // No visible window to host the sheet → never leak silently.
        complete(view: view, state: state, allow: false, content: content)
        return
      }
      presentPrompt(executable: executable, on: window) { [weak self] choice in
        guard let self else { return }
        let result = self.applyChoice(choice, executable: executable, sessionID: sessionID)
        if let rule = result.persist { self.persist(rule) }
        self.complete(view: view, state: state, allow: result.allowed, content: content)
      }
    }
  }

  /// Complete the request, re-fetching the surface NOW. A deferred prompt can
  /// outlive the pane: `tearDownSurface` frees and nils `view.surface`, and it
  /// can run (e.g. via IPC `closeSession`) while a window-modal sheet is open.
  /// Completing against a freed surface would be a use-after-free, so re-check
  /// liveness here and abandon if it's gone. (libghostty doesn't reclaim the
  /// request allocation on surface free — a bounded, documented leak; see the
  /// callback in GhosttyApp.) Empty completion = deny; both free the request
  /// state in the core.
  private func complete(
    view: TerminalSurfaceView, state: UnsafeMutableRawPointer,
    allow: Bool, content: String
  ) {
    guard let surface = view.surface else { return }
    (allow ? content : "").withCString { ptr in
      ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
    }
  }

  private func presentPrompt(
    executable: String, on window: NSWindow, completion: @escaping (Choice) -> Void
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Allow “\(executable)” to read your clipboard?"
    alert.informativeText =
      "A program running in this pane is requesting your clipboard contents via OSC-52."
    // Order matters: first button is the default (rightmost / Return).
    alert.addButton(withTitle: "Deny Once")        // index 1000 (.alertFirstButtonReturn)
    alert.addButton(withTitle: "Allow Once")        // 1001
    alert.addButton(withTitle: "Allow in This Session")  // 1002
    alert.addButton(withTitle: "Allow Always")      // 1003
    alert.addButton(withTitle: "Deny Always")       // 1004
    alert.beginSheetModal(for: window) { response in
      MainActor.assumeIsolated {
        let choice: Choice
        switch response {
        case .alertFirstButtonReturn: choice = .denyOnce
        case NSApplication.ModalResponse(rawValue: 1001): choice = .allowOnce
        case NSApplication.ModalResponse(rawValue: 1002): choice = .allowSession
        case NSApplication.ModalResponse(rawValue: 1003): choice = .allowAlways
        case NSApplication.ModalResponse(rawValue: 1004): choice = .denyAlways
        default: choice = .denyOnce
        }
        completion(choice)
      }
    }
  }
}
