import AppKit
import Foundation

/// Per-window commands that used to be NotificationCenter broadcasts
/// delivered to EVERY window's ContentView (each handler repeating the
/// active-window guard — the fan-out caused at least three documented
/// bugs; see the bell-badge/popup-focus/shift-state comments that lived
/// at the top of ContentView).
///
/// Only the commands ContentView itself handled are modeled here.
/// `misttyRenameTab`/`misttyRenameSession` are deliberately absent: those
/// are consumed by SidebarView/TabBarView (with their own `isActive`/
/// `isEditing` guards), not ContentView, so there is no ContentView body
/// to route.
enum WindowCommand: Equatable, Sendable {
  case newTab(plain: Bool)
  case splitHorizontal(plain: Bool)
  case splitVertical(plain: Bool)
  case sessionManager
  case closePane
  case closeTab
  case reparentSession(sessionID: Int?)
  case windowMode
  case copyMode
  case yankHints(action: HintAction)
  case togglePopup(name: String)
  case focusTab(index: Int)
  case focusSession(index: Int)
  case nextTab
  case prevTab
  case nextSession
  case prevSession
  case moveSessionUp
  case moveSessionDown
  case toggleTabBar
}

/// Resolves the single target window ONCE and delivers typed commands to
/// its registered handler. Ingress stays legacy: the router bridges the
/// existing mistty* notifications (menu items and ShortcutMonitor keep
/// posting them) into typed dispatches — entry points can migrate to
/// direct dispatch() calls later without touching delivery again.
@MainActor
final class WindowCommandRouter {
  private let windowsStore: WindowsStore
  private var handlers: [Int: (WindowCommand) -> Void] = [:]
  private var observers: [NSObjectProtocol] = []

  init(windowsStore: WindowsStore) {
    self.windowsStore = windowsStore
    bridgeLegacyNotifications()
  }

  // No explicit deinit: the router is app-lifetime (created once in
  // MisttyApp, never torn down), and the bridge observers capture `self`
  // weakly so any post that outlives the router is a no-op. A `@MainActor`
  // class can't touch its non-Sendable `observers` from the nonisolated
  // deinit anyway; matching NotificationService/WindowsStore, which also
  // retain their block observers for the process lifetime.

  func register(windowID: Int, handler: @escaping (WindowCommand) -> Void) {
    handlers[windowID] = handler
  }

  func unregister(windowID: Int) {
    handlers[windowID] = nil
  }

  func dispatch(_ command: WindowCommand) {
    guard let target = targetWindow() else { return }
    handlers[target.id]?(command)
  }

  /// Same predicate the per-window guards used, applied once. Falls back
  /// to the store's activeWindow when no window passes the key-state
  /// check (e.g. headless tests, where `isActiveTerminalWindow` returns
  /// false because there is no real key NSWindow).
  private func targetWindow() -> WindowState? {
    windowsStore.windows.first { windowsStore.isActiveTerminalWindow(state: $0) }
      ?? windowsStore.activeWindow
  }

  private func bridge(_ name: Notification.Name, _ make: @escaping @Sendable (Notification) -> WindowCommand?) {
    let token = NotificationCenter.default.addObserver(
      forName: name, object: nil, queue: .main
    ) { [weak self] note in
      // Convert the notification to a Sendable WindowCommand in the
      // (non-isolated) callback body before crossing into the main actor —
      // mirrors NotificationService, which pulls primitives off `note`
      // outside `assumeIsolated` so the Notification never escapes.
      guard let command = make(note) else { return }
      MainActor.assumeIsolated {
        self?.dispatch(command)
      }
    }
    observers.append(token)
  }

  private func bridgeLegacyNotifications() {
    bridge(.misttyNewTab) { _ in .newTab(plain: false) }
    bridge(.misttyNewTabPlain) { _ in .newTab(plain: true) }
    bridge(.misttySplitHorizontal) { _ in .splitHorizontal(plain: false) }
    bridge(.misttySplitHorizontalPlain) { _ in .splitHorizontal(plain: true) }
    bridge(.misttySplitVertical) { _ in .splitVertical(plain: false) }
    bridge(.misttySplitVerticalPlain) { _ in .splitVertical(plain: true) }
    bridge(.misttySessionManager) { _ in .sessionManager }
    bridge(.misttyClosePane) { _ in .closePane }
    bridge(.misttyCloseTab) { _ in .closeTab }
    bridge(.misttyReparentSession) { note in
      .reparentSession(sessionID: note.userInfo?["sessionID"] as? Int)
    }
    bridge(.misttyWindowMode) { _ in .windowMode }
    bridge(.misttyCopyMode) { _ in .copyMode }
    bridge(.misttyYankHints) { _ in .yankHints(action: .copy) }
    bridge(.misttyYankHintsOpen) { _ in .yankHints(action: .open) }
    bridge(.misttyYankHintsCursor) { _ in .yankHints(action: .cursor) }
    bridge(.misttyPopupToggle) { note in
      (note.userInfo?["name"] as? String).map { .togglePopup(name: $0) }
    }
    bridge(.misttyFocusTabByIndex) { note in
      (note.userInfo?["index"] as? Int).map { .focusTab(index: $0) }
    }
    bridge(.misttyFocusSessionByIndex) { note in
      (note.userInfo?["index"] as? Int).map { .focusSession(index: $0) }
    }
    bridge(.misttyNextTab) { _ in .nextTab }
    bridge(.misttyPrevTab) { _ in .prevTab }
    bridge(.misttyNextSession) { _ in .nextSession }
    bridge(.misttyPrevSession) { _ in .prevSession }
    bridge(.misttyMoveSessionUp) { _ in .moveSessionUp }
    bridge(.misttyMoveSessionDown) { _ in .moveSessionDown }
    bridge(.misttyToggleTabBar) { _ in .toggleTabBar }
  }
}
