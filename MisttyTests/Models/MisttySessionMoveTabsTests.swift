import XCTest

@testable import Mistty

@MainActor
final class MisttySessionMoveTabsTests: XCTestCase {

  private func makeSessionWithThreeTabs() -> MisttySession {
    let store = WindowsStore()
    let state = store.createWindow()
    let s = state.createSession(
      name: "proj", directory: URL(fileURLWithPath: "/tmp"))
    s.addTab()
    s.addTab()
    XCTAssertEqual(s.tabs.count, 3)
    return s
  }

  func test_moveTabs_reordersInPlace() {
    let s = makeSessionWithThreeTabs()
    let ids = s.tabs.map(\.id)
    s.moveTabs(from: IndexSet(integer: 0), to: 3)
    XCTAssertEqual(s.tabs.map(\.id), [ids[1], ids[2], ids[0]])
  }

  func test_moveTabs_preservesActiveTabReference() {
    let s = makeSessionWithThreeTabs()
    let originalActive = s.activeTab
    s.moveTabs(from: IndexSet(integer: 0), to: 2)
    XCTAssertEqual(s.activeTab?.id, originalActive?.id,
                   "moving a tab shouldn't change which one is active")
  }
}
