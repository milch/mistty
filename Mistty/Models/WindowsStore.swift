import AppKit
import Foundation
import SwiftUI
import MisttyShared

@Observable
@MainActor
final class WindowsStore {
  // Nested intentionally. The pre-existing top-level `TrackedWindow` in
  // `SessionStore.swift` (different shape — non-weak NSWindow, no state)
  // would clash if this lived at module scope. Even after SessionStore is
  // deleted in Task 12, nesting reads better at call sites
  // (`WindowsStore.TrackedWindow` is more self-documenting than a free
  // `TrackedWindow`), so don't promote.
  struct TrackedWindow {
    let id: Int
    weak var window: NSWindow?
    weak var state: WindowState?
  }

  private(set) var windows: [WindowState] = []
  var activeWindow: WindowState?

  var nextWindowID = 1
  var nextSessionID = 1
  var nextTabID = 1
  var nextPaneID = 1
  var nextPopupID = 1

  var pendingRestoreStates: [WindowState] = []
  /// Set during `restore(...)` and consumed once windows have mounted —
  /// `WindowRootView.drainPendingRestores()` calls
  /// `windowsStore.applyPendingActiveWindow()` to focus the right NSWindow.
  var pendingActiveWindowID: Int?
  var recentlyClosed: [WindowSnapshot] = []
  private(set) var trackedNSWindows: [TrackedWindow] = []
  var openWindowAction: OpenWindowAction?

  // MARK: - ID generation

  func generateWindowID() -> Int {
    let id = nextWindowID
    nextWindowID += 1
    return id
  }

  func generateSessionID() -> Int {
    let id = nextSessionID
    nextSessionID += 1
    return id
  }

  func generateTabID() -> Int {
    let id = nextTabID
    nextTabID += 1
    return id
  }

  func generatePaneID() -> Int {
    let id = nextPaneID
    nextPaneID += 1
    return id
  }

  func generatePopupID() -> Int {
    let id = nextPopupID
    nextPopupID += 1
    return id
  }

  /// Reserve a window id without creating a `WindowState`. Used by IPC
  /// `createWindow` so we can return the id synchronously while the actual
  /// view mount happens asynchronously.
  func reserveNextWindowID() -> Int { generateWindowID() }

  /// Used during state restoration to bump every counter past the highest
  /// id observed in the snapshot, so newly-allocated ids don't collide.
  func advanceIDCounters(windowMax: Int, sessionMax: Int, tabMax: Int, paneMax: Int, popupMax: Int) {
    nextWindowID = max(nextWindowID, windowMax + 1)
    nextSessionID = max(nextSessionID, sessionMax + 1)
    nextTabID = max(nextTabID, tabMax + 1)
    nextPaneID = max(nextPaneID, paneMax + 1)
    nextPopupID = max(nextPopupID, popupMax + 1)
  }

  // MARK: - Window lifecycle

  func createWindow() -> WindowState {
    let state = WindowState(id: generateWindowID(), store: self)
    windows.append(state)
    return state
  }

  func closeWindow(_ state: WindowState) {
    windows.removeAll { $0.id == state.id }
    if activeWindow?.id == state.id { activeWindow = windows.last }
  }

  // MARK: - Lookup helpers

  func window(byId id: Int) -> WindowState? {
    windows.first { $0.id == id }
  }

  func session(byId id: Int) -> (window: WindowState, session: MisttySession)? {
    for window in windows {
      if let session = window.sessions.first(where: { $0.id == id }) {
        return (window, session)
      }
    }
    return nil
  }

  func tab(byId id: Int) -> (window: WindowState, session: MisttySession, tab: MisttyTab)? {
    for window in windows {
      for session in window.sessions {
        if let tab = session.tabs.first(where: { $0.id == id }) {
          return (window, session, tab)
        }
      }
    }
    return nil
  }

  func pane(byId id: Int) -> (window: WindowState, session: MisttySession, tab: MisttyTab, pane: MisttyPane)? {
    for window in windows {
      for session in window.sessions {
        for tab in session.tabs {
          if let pane = tab.panes.first(where: { $0.id == id }) {
            return (window, session, tab, pane)
          }
        }
      }
    }
    return nil
  }

  func popup(byId id: Int) -> (window: WindowState, session: MisttySession, popup: PopupState)? {
    for window in windows {
      for session in window.sessions {
        if let popup = session.popups.first(where: { $0.id == id }) {
          return (window, session, popup)
        }
      }
    }
    return nil
  }

  // MARK: - NSWindow registry

  @discardableResult
  func registerNSWindow(_ window: NSWindow, for state: WindowState) -> Int {
    if let existing = trackedNSWindows.firstIndex(where: { $0.window === window }) {
      // Update binding if the same NSWindow re-registers (e.g. WindowAccessor
      // fires a second time after state restoration).
      let id = trackedNSWindows[existing].id
      trackedNSWindows[existing] = TrackedWindow(id: id, window: window, state: state)
      DebugLog.shared.log(
        "window",
        "registerNSWindow: re-registered id=\(id) windowID=\(state.id) num=\(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow) count=\(trackedNSWindows.count)"
      )
      return id
    }
    let id = state.id
    trackedNSWindows.append(TrackedWindow(id: id, window: window, state: state))
    DebugLog.shared.log(
      "window",
      "registerNSWindow: id=\(id) num=\(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow) count=\(trackedNSWindows.count)"
    )
    return id
  }

  func unregisterNSWindow(_ window: NSWindow) {
    let before = trackedNSWindows.count
    let removedIds = trackedNSWindows
      .filter { $0.window === window }
      .map { $0.id }
    trackedNSWindows.removeAll { $0.window === window }
    DebugLog.shared.log(
      "window",
      "unregisterNSWindow: removed=\(removedIds) num=\(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow) count=\(before)→\(trackedNSWindows.count)"
    )
  }

  func trackedNSWindow(byId id: Int) -> TrackedWindow? {
    trackedNSWindows.first { $0.id == id }
  }

  // MARK: - Focus helpers

  /// True iff the system's keyWindow is one of our tracked terminal windows.
  /// Used to gate app-wide shortcuts like Cmd-W when an auxiliary window
  /// (Settings, etc.) has focus.
  func isTerminalWindowKey() -> Bool {
    guard let key = NSApp.keyWindow else {
      DebugLog.shared.log(
        "cmdw",
        "isTerminalWindowKey=false: no keyWindow, trackedCount=\(trackedNSWindows.count)"
      )
      return false
    }
    let isTracked = trackedNSWindows.contains { $0.window === key }
    if !isTracked {
      DebugLog.shared.log(
        "cmdw",
        "isTerminalWindowKey=false: key=\(ObjectIdentifier(key)) num=\(key.windowNumber) title=\"\(key.title)\" class=\(type(of: key)) trackedIds=\(trackedNSWindows.map(\.id))"
      )
    }
    return isTracked
  }

  /// True iff the system's keyWindow is the NSWindow tracked for `state`.
  /// The window-scoped variant — used by per-window NSEvent monitors and
  /// notification handlers so only the focused window acts.
  func isActiveTerminalWindow(state: WindowState) -> Bool {
    guard let key = NSApp.keyWindow else { return false }
    return trackedNSWindows.contains { $0.window === key && $0.state?.id == state.id }
  }

  /// The `WindowState` whose tracked NSWindow is the keyWindow, if any.
  func focusedWindow() -> WindowState? {
    guard let key = NSApp.keyWindow else { return nil }
    return trackedNSWindows.first { $0.window === key }?.state
  }

  func applyPendingActiveWindow() {
    guard let id = pendingActiveWindowID,
          let tracked = trackedNSWindow(byId: id) else { return }
    pendingActiveWindowID = nil
    tracked.window?.makeKeyAndOrderFront(nil)
    activeWindow = tracked.state
  }
}
