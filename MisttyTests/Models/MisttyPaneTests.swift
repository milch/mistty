import XCTest

@testable import Mistty

/// Tests for `MisttyPane.releaseResources()` — the eager-teardown
/// mechanism that fixed the long-running surface leak (b406c48). The
/// libghostty surface + IOSurface textures + renderer/io threads are
/// held by `TerminalSurfaceView`, which is strong-referenced by
/// `MisttyPane._surfaceView`. SwiftUI's view-tree cache (via
/// `SidebarTabRow`'s `@Bindable tab`, `AttributeGraph`, and Swift's
/// Array COW interaction with `@Observable`) can keep `MisttyPane`
/// instances alive past `closePane`. `releaseResources()` ensures the
/// heavy resources are released anyway.
@MainActor
final class MisttyPaneTests: XCTestCase {

  override func setUp() async throws {
    // Bypass libghostty surface creation — we're testing the Swift
    // ownership graph, not the C surface lifecycle. With the bypass
    // set, the view still constructs but its `surface` stays nil, so
    // `tearDownSurface()`'s `if let surface` no-ops on the C call
    // while still nulling out `_surfaceView`.
    await MainActor.run { TerminalSurfaceView.skipSurfaceCreation = true }
  }

  override func tearDown() async throws {
    await MainActor.run { TerminalSurfaceView.skipSurfaceCreation = false }
  }

  func test_releaseResources_dropsLoadedSurfaceView() {
    let pane = MisttyPane(id: 1)
    _ = pane.surfaceView  // force creation
    XCTAssertNotNil(pane.surfaceViewIfLoaded, "precondition: view should be loaded")

    pane.releaseResources()
    XCTAssertNil(
      pane.surfaceViewIfLoaded,
      "releaseResources should null out the cached surface view so the pane's"
        + " strong ref to it (and through it, the libghostty surface) is dropped")
  }

  func test_releaseResources_idempotent() {
    let pane = MisttyPane(id: 1)
    _ = pane.surfaceView
    pane.releaseResources()
    // A second call must not crash — closePane may run repeatedly via
    // restore/snapshot paths, and surfaceViewIfLoaded is already nil.
    pane.releaseResources()
    XCTAssertNil(pane.surfaceViewIfLoaded)
  }

  func test_releaseResources_safeWhenSurfaceViewNeverLoaded() {
    let pane = MisttyPane(id: 1)
    XCTAssertNil(pane.surfaceViewIfLoaded, "precondition: nothing loaded yet")
    pane.releaseResources()  // no crash
    XCTAssertNil(pane.surfaceViewIfLoaded)
  }

  /// The actual leak invariant — when nothing in the test holds a
  /// strong ref to `MisttyPane` other than the tab's `panes` array,
  /// closing the pane must drop the last strong ref and deallocate
  /// it. If this regresses, a new retention path has appeared in the
  /// pane lifecycle.
  func test_closingLastPaneFreesPane() {
    weak var weakPane: MisttyPane?
    do {
      var nextID = 0
      let tab = MisttyTab(id: 1, paneIDGenerator: { nextID += 1; return nextID })
      let pane = tab.activePane!
      weakPane = pane
      _ = pane.surfaceView  // exercise the full path including teardown
      tab.closePane(pane)
      // `pane` local + `tab.panes` (now empty) + `tab.layout.root` (now
      // .empty) were the strong refs. After `closePane`, only the test's
      // `pane` local remains; that goes away at end of `do`.
    }
    XCTAssertNil(
      weakPane,
      "Closed pane must be deallocated when no external (test/SwiftUI) ref"
        + " holds it — see b406c48 / leak hunt thread")
  }
}
