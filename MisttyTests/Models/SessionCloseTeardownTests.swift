import XCTest

@testable import Mistty

/// Regression tests for the surface-teardown gap found in the 2026-06
/// audit: `closePane` released surfaces but `closeTab` / `closeSession` /
/// `closeWindow` did not, leaking renderer threads + IOSurfaces + shell
/// processes on every tab/session/window close (same class as b406c48).
@MainActor
final class SessionCloseTeardownTests: XCTestCase {
  private var windowsStore: WindowsStore!
  private var state: WindowState!

  override func setUp() async throws {
    await MainActor.run {
      TerminalSurfaceView.skipSurfaceCreation = true
      windowsStore = WindowsStore()
      state = windowsStore.createWindow()
    }
  }

  override func tearDown() async throws {
    await MainActor.run {
      TerminalSurfaceView.skipSurfaceCreation = false
      state = nil
      windowsStore = nil
    }
  }

  private func makeSession() -> MisttySession {
    state.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
  }

  func test_closeTab_releasesAllPaneSurfaces() {
    let session = makeSession()
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    let panes = tab.panes
    panes.forEach { _ = $0.surfaceView }  // force load
    XCTAssertTrue(
      panes.allSatisfy { $0.surfaceViewIfLoaded != nil }, "precondition: views loaded")

    session.closeTab(tab)

    for pane in panes {
      XCTAssertNil(
        pane.surfaceViewIfLoaded,
        "closeTab must release every contained pane's surface")
    }
  }

  func test_closeSession_releasesTabPanesAndPopupPanes() {
    let session = makeSession()
    let tab = session.tabs[0]
    tab.splitActivePane(direction: .horizontal)
    session.togglePopup(definition: PopupDefinition(name: "scratch", command: "top"))
    let panes = tab.panes
    let popupPane = session.popups[0].pane
    (panes + [popupPane]).forEach { _ = $0.surfaceView }  // force load

    state.closeSession(session)

    for pane in panes + [popupPane] {
      XCTAssertNil(
        pane.surfaceViewIfLoaded,
        "closeSession must release every tab pane and popup pane surface")
    }
  }
}
