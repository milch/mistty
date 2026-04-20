import XCTest

@testable import Mistty

@MainActor
final class MisttyTabTests: XCTestCase {
  private var store: SessionStore!

  override func setUp() async throws {
    await MainActor.run {
      store = SessionStore()
    }
  }

  override func tearDown() async throws {
    await MainActor.run {
      for session in store.sessions { store.closeSession(session) }
      store = nil
    }
  }

  private func makeTab() -> MisttyTab {
    let session = store.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
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
}
