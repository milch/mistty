import XCTest

@testable import Mistty

@MainActor
final class WindowCommandRouterTests: XCTestCase {
  func test_dispatch_reachesOnlyActiveWindowHandler() {
    let store = WindowsStore()
    let w1 = store.createWindow()
    let w2 = store.createWindow()
    store.activeWindow = w2
    let router = WindowCommandRouter(windowsStore: store)

    var w1Got: [WindowCommand] = []
    var w2Got: [WindowCommand] = []
    router.register(windowID: w1.id) { w1Got.append($0) }
    router.register(windowID: w2.id) { w2Got.append($0) }

    router.dispatch(.nextTab)

    XCTAssertEqual(w1Got, [])
    XCTAssertEqual(w2Got, [.nextTab])
  }

  func test_dispatch_afterUnregister_isNoOp() {
    let store = WindowsStore()
    let w = store.createWindow()
    store.activeWindow = w
    let router = WindowCommandRouter(windowsStore: store)
    var got: [WindowCommand] = []
    router.register(windowID: w.id) { got.append($0) }
    router.unregister(windowID: w.id)
    router.dispatch(.closePane)
    XCTAssertEqual(got, [])
  }

  func test_legacyNotification_isBridgedToTypedCommand() {
    let store = WindowsStore()
    let w = store.createWindow()
    store.activeWindow = w
    let router = WindowCommandRouter(windowsStore: store)
    var got: [WindowCommand] = []
    router.register(windowID: w.id) { got.append($0) }

    NotificationCenter.default.post(name: .misttyFocusTabByIndex, object: nil,
                                    userInfo: ["index": 3])
    NotificationCenter.default.post(name: .misttyYankHintsOpen, object: nil)

    XCTAssertEqual(got, [.focusTab(index: 3), .yankHints(action: .open)])
  }

  /// Targeting falls back to `activeWindow` in the headless test environment:
  /// `isActiveTerminalWindow` returns false without a real key NSWindow, so
  /// the router resolves the target via the documented `?? activeWindow`
  /// order. This is the contract ContentView relies on at runtime (where the
  /// key-state predicate does the real work).
  func test_targeting_fallsBackToActiveWindow_whenNoKeyWindow() {
    let store = WindowsStore()
    _ = store.createWindow()
    let w2 = store.createWindow()
    store.activeWindow = w2
    let router = WindowCommandRouter(windowsStore: store)
    var got: [WindowCommand] = []
    router.register(windowID: w2.id) { got.append($0) }
    router.dispatch(.prevTab)
    XCTAssertEqual(got, [.prevTab])
  }
}
