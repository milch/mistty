import XCTest

@testable import Mistty

@MainActor
final class MisttyTabTests: XCTestCase {
  private var windowsStore: WindowsStore!
  private var state: WindowState!

  override func setUp() async throws {
    await MainActor.run {
      windowsStore = WindowsStore()
      state = windowsStore.createWindow()
    }
  }

  override func tearDown() async throws {
    await MainActor.run {
      for session in state.sessions { state.closeSession(session) }
      state = nil
      windowsStore = nil
    }
  }

  private func makeTab() -> MisttyTab {
    let session = state.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    return session.tabs[0]
  }

  func test_closeActivePane_resetsTitleToNewActivesProcessTitle() {
    let tab = makeTab()
    tab.splitActivePane(direction: .horizontal)
    let first = tab.panes[0]
    let second = tab.panes[1]
    first.processTitle = "nvim"
    second.processTitle = "zsh"
    tab.activePane = second
    tab.title = "zsh"

    tab.closePane(second)

    XCTAssertEqual(tab.activePane?.id, first.id)
    XCTAssertEqual(tab.title, "nvim")
  }

  func test_closeActivePane_resetsTitleToDefaultWhenNewActiveHasNoProcessTitle() {
    let tab = makeTab()
    tab.splitActivePane(direction: .horizontal)
    let second = tab.panes[1]
    tab.activePane = second
    tab.title = "something-that-became-stale"

    tab.closePane(second)

    XCTAssertEqual(tab.title, "Shell")
  }

  func test_closeNonActivePane_keepsTitle() {
    let tab = makeTab()
    tab.splitActivePane(direction: .horizontal)
    let first = tab.panes[0]
    let second = tab.panes[1]
    first.processTitle = "nvim"
    second.processTitle = "zsh"
    tab.activePane = second
    tab.title = "zsh"

    tab.closePane(first)

    XCTAssertEqual(tab.title, "zsh")
  }

  // MARK: - Resource teardown (b406c48 regression)

  /// `closePane` must drop the pane from `tab.panes` (the source of
  /// truth) and from `tab.layout.leafIDs` (the shape). Both used to be
  /// derived from the layout enum's leaf payload; after the
  /// pane-IDs-in-leaves refactor they're maintained independently.
  func test_closePane_removesFromPanesAndLayout() {
    let tab = makeTab()
    tab.splitActivePane(direction: .horizontal)
    let closing = tab.panes[1]
    let surviving = tab.panes[0]

    tab.closePane(closing)

    XCTAssertEqual(tab.panes.map(\.id), [surviving.id])
    XCTAssertEqual(tab.layout.leafIDs, [surviving.id])
  }

  /// Closing a pane must call `releaseResources()` on it so the
  /// libghostty surface + threads + IOSurface textures are released
  /// eagerly. Without this, SwiftUI's view-tree cache keeps the
  /// `TerminalSurfaceView` alive and the surface accumulates
  /// (~5GB / 17 days in the worst case investigated in b406c48).
  func test_closePane_releasesPaneSurface() {
    TerminalSurfaceView.skipSurfaceCreation = true
    defer { TerminalSurfaceView.skipSurfaceCreation = false }

    let tab = makeTab()
    tab.splitActivePane(direction: .horizontal)
    let closing = tab.panes[1]
    _ = closing.surfaceView  // force load
    XCTAssertNotNil(closing.surfaceViewIfLoaded, "precondition: view loaded")

    tab.closePane(closing)

    XCTAssertNil(
      closing.surfaceViewIfLoaded,
      "closePane must invoke releaseResources() on the closed pane so its"
        + " libghostty surface is freed regardless of SwiftUI cache retention")
  }

  /// Window-mode join/break MOVE a pane between tabs. The move must not
  /// tear down the pane's surface — releasing it kills the running shell
  /// and silently respawns a fresh one. Regression: join/break (b01f1b8)
  /// predate the closePane teardown (b406c48), which made every pane move
  /// destroy the moved pane's process.
  func test_detachPane_keepsSurfaceAlive() {
    TerminalSurfaceView.skipSurfaceCreation = true
    defer { TerminalSurfaceView.skipSurfaceCreation = false }

    let tab = makeTab()
    tab.splitActivePane(direction: .horizontal)
    let moving = tab.panes[1]
    _ = moving.surfaceView  // force load
    XCTAssertNotNil(moving.surfaceViewIfLoaded, "precondition: view loaded")

    tab.detachPane(moving)

    XCTAssertEqual(tab.panes.count, 1)
    XCTAssertFalse(tab.layout.leafIDs.contains(moving.id))
    XCTAssertNotNil(
      moving.surfaceViewIfLoaded,
      "detachPane must keep the moved pane's surface alive — join/break"
        + " re-attach the pane to another tab")
  }

  /// Closing the *last* pane in a tab — `tab.panes` ends up empty,
  /// `tab.layout.root` collapses to `.empty`, and the pane's resources
  /// are torn down. Caller (session) closes the tab afterward; that's
  /// out of scope here.
  func test_closeLastPane_emptiesEverything() {
    TerminalSurfaceView.skipSurfaceCreation = true
    defer { TerminalSurfaceView.skipSurfaceCreation = false }

    let tab = makeTab()
    let only = tab.activePane!
    _ = only.surfaceView

    tab.closePane(only)

    XCTAssertTrue(tab.panes.isEmpty)
    XCTAssertTrue(tab.layout.leafIDs.isEmpty)
    XCTAssertNil(tab.activePane)
    XCTAssertNil(only.surfaceViewIfLoaded)
  }

  /// Defensive: closing a `zoomedPane` must also clear that property.
  /// Otherwise the strong `MisttyTab.zoomedPane` keeps the closed pane
  /// alive in the model layer, undoing the close.
  func test_closeZoomedPane_clearsZoomReference() {
    let tab = makeTab()
    tab.splitActivePane(direction: .horizontal)
    let zoomed = tab.panes[1]
    tab.zoomedPane = zoomed

    tab.closePane(zoomed)

    XCTAssertNil(tab.zoomedPane, "Closing the zoomed pane must clear zoomedPane")
  }
}
