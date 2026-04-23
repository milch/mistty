import XCTest
@testable import MisttyShared

final class WorkspaceSnapshotTests: XCTestCase {
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }

  func test_paneSnapshot_roundTrip() throws {
    let pane = PaneSnapshot(
      id: 5,
      directory: URL(fileURLWithPath: "/tmp"),
      currentWorkingDirectory: URL(fileURLWithPath: "/tmp/work"),
      captured: CapturedProcess(executable: "nvim", argv: ["nvim", "foo.txt"])
    )
    XCTAssertEqual(try roundTrip(pane), pane)
  }

  func test_paneSnapshot_roundTripWithoutCaptured() throws {
    let pane = PaneSnapshot(id: 1, directory: nil, currentWorkingDirectory: nil, captured: nil)
    XCTAssertEqual(try roundTrip(pane), pane)
  }

  func test_layoutLeaf_roundTrip() throws {
    let leaf = LayoutNodeSnapshot.leaf(pane: PaneSnapshot(id: 1))
    XCTAssertEqual(try roundTrip(leaf), leaf)
  }

  func test_layoutSplit_roundTrip() throws {
    let split = LayoutNodeSnapshot.split(
      direction: .horizontal,
      a: .leaf(pane: PaneSnapshot(id: 1)),
      b: .leaf(pane: PaneSnapshot(id: 2)),
      ratio: 0.4
    )
    XCTAssertEqual(try roundTrip(split), split)
  }

  func test_layoutNested_roundTrip() throws {
    let tree = LayoutNodeSnapshot.split(
      direction: .vertical,
      a: .split(
        direction: .horizontal,
        a: .leaf(pane: PaneSnapshot(id: 1)),
        b: .leaf(pane: PaneSnapshot(id: 2)),
        ratio: 0.6
      ),
      b: .leaf(pane: PaneSnapshot(id: 3)),
      ratio: 0.5
    )
    XCTAssertEqual(try roundTrip(tree), tree)
  }
}
