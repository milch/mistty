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
