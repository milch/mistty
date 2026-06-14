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
}
