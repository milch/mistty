import XCTest

@testable import Mistty

@MainActor
final class FrecencyServiceTests: XCTestCase {
  var service: FrecencyService!
  var testURL: URL!

  override func setUp() {
    testURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("frecency-test-\(UUID().uuidString).json")
    service = FrecencyService(storageURL: testURL)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: testURL)
  }

  func test_scoreIsZeroForUnknownKey() {
    XCTAssertEqual(service.score(for: "session:unknown"), 0)
  }

  func test_recordAccessIncreasesScore() {
    service.recordAccess(for: "session:project")
    XCTAssertGreaterThan(service.score(for: "session:project"), 0)
  }

  func test_multipleAccessesIncreaseScore() {
    service.recordAccess(for: "session:a")
    let score1 = service.score(for: "session:a")
    service.recordAccess(for: "session:a")
    let score2 = service.score(for: "session:a")
    XCTAssertGreaterThan(score2, score1)
  }

  func test_persistsToDisk() {
    service.recordAccess(for: "dir:/tmp")
    let score = service.score(for: "dir:/tmp")
    let service2 = FrecencyService(storageURL: testURL)
    XCTAssertEqual(service2.score(for: "dir:/tmp"), score)
  }

  func test_recentAccessScoresHigher() {
    service.recordAccess(for: "ssh:old")
    service.setLastAccessed(for: "ssh:old", date: Date().addingTimeInterval(-30 * 24 * 3600))
    let oldScore = service.score(for: "ssh:old")
    service.recordAccess(for: "ssh:new")
    let newScore = service.score(for: "ssh:new")
    XCTAssertGreaterThan(newScore, oldScore)
  }
}
