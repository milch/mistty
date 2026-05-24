import AppKit
import Foundation
import UserNotifications

/// Resolve the title shown in a macOS notification. OSC 9 carries no title,
/// so fall back through the emitting pane's process title, then the session
/// label, then a constant. Whitespace-only values are treated as empty.
func resolveNotificationTitle(
  rawTitle: String, processTitle: String?, sessionLabel: String
) -> String {
  let raw = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  if !raw.isEmpty { return raw }
  if let processTitle = processTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
    !processTitle.isEmpty
  {
    return processTitle
  }
  let label = sessionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
  if !label.isEmpty { return label }
  return "Mistty"
}

/// True when the user is actively looking at the tab that emitted the
/// notification: Mistty frontmost, its window active, that window's active
/// session matching, and that session's active tab matching. Mirrors
/// `ContentView.handleRingBell`'s visibility check (tab granularity — a
/// visible split-peer pane counts as "seen"). When true, no banner is shown.
func isUserViewingTab(
  appActive: Bool, windowActive: Bool, sessionActive: Bool, tabActive: Bool
) -> Bool {
  appActive && windowActive && sessionActive && tabActive
}

/// Owns the macOS desktop-notification integration. A single instance
/// (`shared`) consumes the in-process `.ghosttyDesktopNotification` event
/// exactly once — handling it per-window would post one banner per window.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationService()

  private weak var windowsStore: WindowsStore?
  private var didRequestAuthorization = false

  private override init() { super.init() }

  /// Wire up the service. Called once from `MisttyApp.init()` after the
  /// `WindowsStore` exists.
  func start(windowsStore: WindowsStore) {
    self.windowsStore = windowsStore
    UNUserNotificationCenter.current().delegate = self

    NotificationCenter.default.addObserver(
      forName: .ghosttyDesktopNotification, object: nil, queue: .main
    ) { [weak self] note in
      let rawTitle = note.userInfo?["title"] as? String ?? ""
      let body = note.userInfo?["body"] as? String ?? ""
      let paneID = note.userInfo?["paneID"] as? Int
      MainActor.assumeIsolated { self?.handleDesktopNotification(rawTitle: rawTitle, body: body, paneID: paneID) }
    }
    NotificationCenter.default.addObserver(
      forName: .misttyConfigDidReload, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.requestAuthorizationIfExplicitlyEnabled() }
    }

    // Defer the initial eager request one runloop tick so it doesn't run
    // mid-`MisttyApp.init()`.
    DispatchQueue.main.async { [weak self] in
      self?.requestAuthorizationIfExplicitlyEnabled()
    }
  }

  /// Request authorization up front, but only when the user explicitly wrote
  /// `[notifications] enabled = true`. Fresh installs that never touched the
  /// config are not prompted until the first notification actually fires.
  private func requestAuthorizationIfExplicitlyEnabled() {
    guard MisttyConfig.current.notifications.explicitlyEnabled else { return }
    requestAuthorizationIfNeeded()
  }

  /// Request macOS notification authorization at most once per process.
  private func requestAuthorizationIfNeeded() {
    guard !didRequestAuthorization else { return }
    didRequestAuthorization = true
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
  }

  private func handleDesktopNotification(rawTitle: String, body: String, paneID: Int?) {
    guard MisttyConfig.current.notifications.enabled else { return }

    // Default title for the unresolvable-pane path (pane closed between
    // emission and dispatch, or no surface userdata). Trim so a whitespace-
    // only title falls back, mirroring `resolveNotificationTitle`.
    let trimmedRaw = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    var title = trimmedRaw.isEmpty ? "Mistty" : trimmedRaw
    var threadID: String?

    if let paneID, let store = windowsStore, let resolved = store.pane(byId: paneID) {
      let viewing = isUserViewingTab(
        appActive: NSApp.isActive,
        windowActive: store.activeWindow?.id == resolved.window.id,
        sessionActive: resolved.window.activeSession?.id == resolved.session.id,
        tabActive: resolved.session.activeTab?.id == resolved.tab.id)
      // The user is already looking at the tab — no banner, no flag.
      if viewing { return }
      resolved.tab.hasBell = true
      store.updateDockBadge()
      title = resolveNotificationTitle(
        rawTitle: rawTitle,
        processTitle: resolved.pane.processTitle,
        sessionLabel: resolved.session.sidebarLabel)
      threadID = String(resolved.session.id)
    }

    requestAuthorizationIfNeeded()
    postBanner(title: title, body: body, paneID: paneID, threadID: threadID)
  }

  private func postBanner(title: String, body: String, paneID: Int?, threadID: String?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let threadID { content.threadIdentifier = threadID }
    if let paneID { content.userInfo = ["paneID": paneID] }
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in }
  }

  /// Focus the pane that emitted a notification the user clicked.
  private func focusPane(paneID: Int?) {
    NSApp.activate(ignoringOtherApps: true)
    guard let paneID, let store = windowsStore,
      let resolved = store.pane(byId: paneID)
    else { return }
    store.trackedNSWindow(byId: resolved.window.id)?.window?.makeKeyAndOrderFront(nil)
    resolved.window.activeSession = resolved.session
    resolved.session.activeTab = resolved.tab
    resolved.tab.focusPane(resolved.pane)
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Every banner we post has already passed the `isUserViewingTab` check,
    // so it always deserves to show — including while Mistty is frontmost.
    completionHandler([.banner, .list])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let paneID = response.notification.request.content.userInfo["paneID"] as? Int
    Task { @MainActor in
      self.focusPane(paneID: paneID)
    }
    completionHandler()
  }
}
