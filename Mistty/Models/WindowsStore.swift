import AppKit
import Foundation
import SwiftUI

// Forward-declared in Task 1 so WindowsStore compiles. Task 2 fleshes
// this out with sessions, activeSession, and the relocated session-management
// methods. Do not add behavior here.
@Observable
@MainActor
final class WindowState {
  let id: Int
  unowned let store: WindowsStore

  init(id: Int, store: WindowsStore) {
    self.id = id
    self.store = store
  }
}

@Observable
@MainActor
final class WindowsStore {
  private(set) var windows: [WindowState] = []
  var activeWindow: WindowState?

  var nextWindowID = 1
  var nextSessionID = 1
  var nextTabID = 1
  var nextPaneID = 1
  var nextPopupID = 1

  var pendingRestoreStates: [WindowState] = []
  var recentlyClosed: [_PlaceholderWindowSnapshot] = []

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
}

// Placeholder — the real `WindowSnapshot` arrives in Phase 2 (Task 4).
// Defined here as `_PlaceholderWindowSnapshot` aliased so we can swap later.
typealias _PlaceholderWindowSnapshot = Void
