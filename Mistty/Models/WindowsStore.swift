import AppKit
import Foundation
import SwiftUI
import MisttyShared

@Observable
@MainActor
final class WindowsStore {
  // Nested intentionally: `WindowsStore.TrackedWindow` is more
  // self-documenting at call sites than a free `TrackedWindow` at module scope.
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
  /// Set once any `WindowRootView` schedules the deferred drain; prevents
  /// every mounting onAppear from scheduling its own drain.
  private var drainScheduled: Bool = false

  /// How long to wait after the first WindowRootView mounts before draining
  /// any pending restore states that SwiftUI's `WindowGroup` auto-restore
  /// didn't already claim. Empirical — chosen to comfortably outlast
  /// SwiftUI's own restore-then-mount round trip on a typical machine.
  /// Too short → over-fire, end up with extra empty windows; too long →
  /// perceptible delay before the rest of the user's windows materialize
  /// on cold launch. 250ms is the rough middle. If users on slower
  /// hardware ever report extra-empty-window regressions, this is the
  /// first constant to bump.
  private static let pendingRestoreDrainDelay: TimeInterval = 0.25

  init() {
    // Mirror `NSApp.keyWindow` into `activeWindow` so IPC sentinels
    // (`active`, `sendKeys paneId=0`, `getText paneId=0`,
    // `focusPaneByDirection sessionId=0`) and the bell handler always see
    // the currently focused terminal window — not the last-created one.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self, let key = note.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        self.activeWindow = self.trackedNSWindows.first { $0.window === key }?.state
      }
    }
  }

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
    // Idempotency guard: if the window is no longer in our list (e.g. called
    // twice from onDisappear races), skip the snapshot so we don't push a
    // duplicate onto recentlyClosed.
    guard windows.contains(where: { $0.id == state.id }) else { return }

    // Skip the recently-closed snapshot for empty windows. Cmd+W on an
    // empty window legitimately closes it, but pushing nothing-states onto
    // the LIFO stack would let several empties mask a genuine prior closed
    // window with content (capacity is 10), and reopening an empty window
    // is just busywork.
    guard !state.sessions.isEmpty else {
      windows.removeAll { $0.id == state.id }
      if activeWindow?.id == state.id { activeWindow = windows.last }
      return
    }

    // Snapshot into recently-closed before removal so Reopen Closed Window
    // can rehydrate. In-memory only — wiped on app quit. Uses the same
    // snapshotLayout helper as takeSnapshot() so foreground-process capture
    // works the same way: nvim, claude, ssh, etc. relaunch on reopen
    // (subject to the user's [[restore.command]] allowlist).
    let snapshot = WindowSnapshot(
      id: state.id,
      sessions: state.sessions.map { session in
        SessionSnapshot(
          id: session.id,
          name: session.name,
          customName: session.customName,
          directory: session.directory,
          sshCommand: session.sshCommand,
          lastActivatedAt: session.lastActivatedAt,
          tabs: session.tabs.map { tab in
            TabSnapshot(
              id: tab.id, customTitle: tab.customTitle, directory: tab.directory,
              layout: snapshotLayout(tab.layout.root),
              activePaneID: tab.activePane?.id)
          },
          activeTabID: session.activeTab?.id)
      },
      activeSessionID: state.activeSession?.id
    )
    recentlyClosed.insert(snapshot, at: 0)
    if recentlyClosed.count > 10 {
      recentlyClosed.removeLast(recentlyClosed.count - 10)
    }
    windows.removeAll { $0.id == state.id }
    if activeWindow?.id == state.id { activeWindow = windows.last }
  }

  /// Pop the most recently closed window and queue it for restore.
  /// Caller fires `openWindowAction(id: "terminal")` to spawn the window.
  func reopenMostRecentClosed() -> Int? {
    guard let snapshot = recentlyClosed.first else { return nil }
    recentlyClosed.removeFirst()

    // Rehydrate the WindowState from the in-memory snapshot using the
    // same restore path as quit-relaunch. Fresh session IDs are minted —
    // tab/pane IDs are preserved from the snapshot via restoreTab. ID
    // counters monotonically increase, so reused IDs can't collide; we
    // mint fresh session IDs only because session IDs are surfaced via
    // the sidebar/IPC and a stale ID across a close/reopen would be
    // confusing.
    let state = WindowState(id: reserveNextWindowID(), store: self)
    let config = MisttyConfig.current.restore
    let tabIDGen: () -> Int = { [weak self] in self?.generateTabID() ?? 0 }
    let paneIDGen: () -> Int = { [weak self] in self?.generatePaneID() ?? 0 }
    let popupIDGen: () -> Int = { [weak self] in self?.generatePopupID() ?? 0 }
    var maxPaneID = 0  // restoreTab requires it inout; unused after the loop

    for sessionSnap in snapshot.sessions {
      let session = MisttySession(
        id: generateSessionID(),
        name: sessionSnap.name,
        directory: sessionSnap.directory,
        exec: nil,
        customName: sessionSnap.customName,
        tabIDGenerator: tabIDGen,
        paneIDGenerator: paneIDGen,
        popupIDGenerator: popupIDGen)
      session.sshCommand = sessionSnap.sshCommand
      for tab in session.tabs { session.closeTab(tab) }
      for tabSnap in sessionSnap.tabs {
        let tab = WindowsStore.restoreTab(
          from: tabSnap, paneIDGen: paneIDGen,
          config: config, maxPaneID: &maxPaneID)
        session.addTabByRestore(tab)
      }
      session.activeTab = session.tabs.first
      state.appendRestoredSession(session)
    }
    state.activeSession = state.sessions.first
    pendingRestoreStates.append(state)
    return state.id
  }

  // MARK: - Lookup helpers

  /// Resolve a window by id. Includes both the live `windows` list and
  /// `pendingRestoreStates` — a window-id returned by `createWindow`/IPC
  /// is reserved synchronously and pushed into the pending queue, but the
  /// SwiftUI mount that promotes it into `windows` happens in a later
  /// runloop tick. Without checking the pending queue, a script that runs
  /// `window create` then immediately `session create --window <id>` would
  /// race with the mount and get "window not found".
  func window(byId id: Int) -> WindowState? {
    if let live = windows.first(where: { $0.id == id }) { return live }
    return pendingRestoreStates.first { $0.id == id }
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
    guard let app = NSApp, let key = app.keyWindow else {
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
    guard let app = NSApp, let key = app.keyWindow else { return false }
    return trackedNSWindows.contains { $0.window === key && $0.state?.id == state.id }
  }

  /// IPC `createWindow` path. Reserves an id synchronously, builds an empty
  /// `WindowState`, and pushes it onto `pendingRestoreStates` so the next
  /// SwiftUI mount claims it. Returns the reserved id; the caller fires
  /// `openWindowAction` to actually spawn the SwiftUI window.
  func prepareWindowForIPCCreate() -> Int {
    let state = WindowState(id: reserveNextWindowID(), store: self)
    pendingRestoreStates.append(state)
    return state.id
  }

  /// Resolve the target window for a window-scoped create operation.
  /// `explicit` wins; otherwise we fall back to the focused terminal
  /// window. Returns nil if neither resolves.
  func resolveTargetWindow(explicit: Int?) -> WindowState? {
    if let explicit { return window(byId: explicit) }
    return focusedWindow()
  }

  /// The `WindowState` whose tracked NSWindow is the keyWindow, if any.
  func focusedWindow() -> WindowState? {
    guard let app = NSApp, let key = app.keyWindow else { return nil }
    return trackedNSWindows.first { $0.window === key }?.state
  }

  func applyPendingActiveWindow() {
    guard let id = pendingActiveWindowID,
          let tracked = trackedNSWindow(byId: id) else { return }
    pendingActiveWindowID = nil
    tracked.window?.makeKeyAndOrderFront(nil)
    activeWindow = tracked.state
  }

  // MARK: - Restore helpers

  /// Append a window state that arrived through `restore(...)`. The
  /// state's `id` was assigned from the snapshot, so we don't generate a
  /// fresh one — but `advanceIDCounters` already bumped past it.
  func registerRestoredWindow(_ state: WindowState) {
    if !windows.contains(where: { $0.id == state.id }) {
      windows.append(state)
    }
  }

  /// Drain any remaining pending restore states by firing `openWindow` once
  /// per state still queued. Called after a delay so SwiftUI's own
  /// `WindowGroup` auto-restore (which can spawn windows that ALSO claim
  /// pending states via their `onAppear`) has time to finish first;
  /// otherwise we'd over-fire and end up with extra empty windows.
  ///
  /// Idempotent — only the first `WindowRootView.onAppear` arms the timer,
  /// and the timer fires exactly once with whatever count remains at that
  /// point. If SwiftUI auto-restore claimed everything, this is a no-op.
  func drainPendingRestores() {
    guard openWindowAction != nil, !drainScheduled else { return }
    drainScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pendingRestoreDrainDelay) { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated {
        let remaining = self.pendingRestoreStates.count
        for _ in 0..<remaining {
          self.openWindowAction?(id: "terminal")
        }
        self.drainScheduled = false
      }
    }
  }
}
