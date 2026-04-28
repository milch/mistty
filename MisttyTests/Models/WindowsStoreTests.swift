import Foundation
import Testing
@testable import Mistty

@MainActor
struct WindowsStoreTests {
  @Test
  func generatesGloballyUniqueIDs() {
    let store = WindowsStore()
    #expect(store.generateSessionID() == 1)
    #expect(store.generateTabID() == 1)
    #expect(store.generatePaneID() == 1)
    #expect(store.generatePopupID() == 1)
    #expect(store.generateWindowID() == 1)
    #expect(store.generateSessionID() == 2)
    #expect(store.generateWindowID() == 2)
  }

  @Test
  func reserveNextWindowIDAdvancesCounter() {
    let store = WindowsStore()
    let id = store.reserveNextWindowID()
    #expect(id == 1)
    #expect(store.generateWindowID() == 2)
  }

  @Test
  func createWindowAppendsAndAssignsID() {
    let store = WindowsStore()
    let a = store.createWindow()
    let b = store.createWindow()
    #expect(store.windows.count == 2)
    #expect(a.id == 1)
    #expect(b.id == 2)
  }

  @Test
  func closeWindowRemovesFromList() {
    let store = WindowsStore()
    let a = store.createWindow()
    _ = store.createWindow()
    store.closeWindow(a)
    #expect(store.windows.count == 1)
    #expect(store.windows.first?.id == 2)
  }

  @Test
  func advanceIDCountersJumpsPastMax() {
    let store = WindowsStore()
    store.advanceIDCounters(windowMax: 5, sessionMax: 10, tabMax: 20, paneMax: 30, popupMax: 40)
    #expect(store.generateWindowID() == 6)
    #expect(store.generateSessionID() == 11)
    #expect(store.generateTabID() == 21)
    #expect(store.generatePaneID() == 31)
    #expect(store.generatePopupID() == 41)
  }
}

@MainActor
struct WindowsStoreLookupTests {
  @Test
  func sessionByIdFindsAcrossWindows() {
    let store = WindowsStore()
    let a = store.createWindow()
    let b = store.createWindow()
    let s1 = a.createSession(name: "a", directory: URL(fileURLWithPath: "/"))
    let s2 = b.createSession(name: "b", directory: URL(fileURLWithPath: "/"))

    let foundA = store.session(byId: s1.id)
    let foundB = store.session(byId: s2.id)
    #expect(foundA?.window.id == a.id)
    #expect(foundA?.session.id == s1.id)
    #expect(foundB?.window.id == b.id)
    #expect(foundB?.session.id == s2.id)
    #expect(store.session(byId: 99) == nil)
  }

  @Test
  func windowByIdFindsExisting() {
    let store = WindowsStore()
    let a = store.createWindow()
    #expect(store.window(byId: a.id)?.id == a.id)
    #expect(store.window(byId: 999) == nil)
  }

  /// Regression test: ghostty's close-surface callback identifies the surface
  /// by *pane* id, not popup id. The handler in `ContentView.handleCloseSurface`
  /// must therefore look up popups by their pane's id — using the popup's own
  /// id silently misses (the pane and popup id counters are independent).
  /// When this lookup fails, popups with `close_on_exit = true` get stuck
  /// showing ghostty's "Process exited. Press any key to close the terminal."
  /// message instead of closing.
  @Test
  func popupByPaneIdFindsTheRightPopup() throws {
    let store = WindowsStore()
    let window = store.createWindow()
    let session = window.createSession(name: "s", directory: URL(fileURLWithPath: "/"))
    session.openPopup(definition: PopupDefinition(name: "p", command: "true"))

    let popup = try #require(session.popups.first)
    let paneID = popup.pane.id

    let resolved = try #require(store.popup(byPaneId: paneID))
    #expect(resolved.popup.id == popup.id)
    #expect(resolved.session.id == session.id)
    #expect(resolved.window.id == window.id)
    #expect(store.popup(byPaneId: 9_999) == nil)
  }
}

@MainActor
struct WindowsStoreRecentlyClosedTests {
  @Test
  func closeWindowSnapshotsIntoRecentlyClosed() {
    let store = WindowsStore()
    let state = store.createWindow()
    let session = state.createSession(name: "demo", directory: URL(fileURLWithPath: "/tmp"))
    store.closeWindow(state)
    #expect(store.recentlyClosed.count == 1)
    #expect(store.recentlyClosed[0].sessions.count == 1)
    #expect(store.recentlyClosed[0].sessions[0].id == session.id)
  }

  @Test
  func recentlyClosedCappedAtTen() {
    let store = WindowsStore()
    for _ in 0..<15 {
      let state = store.createWindow()
      store.closeWindow(state)
    }
    #expect(store.recentlyClosed.count == 10)
  }

  @Test
  func reopenMostRecentPushesOntoPendingRestoreStates() {
    let store = WindowsStore()
    let state = store.createWindow()
    _ = state.createSession(name: "demo", directory: URL(fileURLWithPath: "/tmp"))
    store.closeWindow(state)
    let restored = store.reopenMostRecentClosed()
    #expect(restored != nil)
    #expect(store.pendingRestoreStates.count == 1)
    #expect(store.recentlyClosed.isEmpty)
  }
}
