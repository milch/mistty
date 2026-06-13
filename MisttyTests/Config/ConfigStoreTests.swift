import XCTest

@testable import Mistty

@MainActor
final class ConfigStoreTests: XCTestCase {
  func test_config_reflectsCurrentAtInit() {
    let store = ConfigStore()
    XCTAssertEqual(store.config.sidebarVisible, MisttyConfig.current.sidebarVisible)
  }

  func test_refresh_picksUpReload() {
    let store = ConfigStore()
    let original = MisttyConfig.current
    defer { MisttyConfig.current = original }

    var changed = original
    changed.sidebarVisible.toggle()
    MisttyConfig.current = changed
    NotificationCenter.default.post(name: .misttyConfigDidReload, object: nil)

    XCTAssertEqual(store.config.sidebarVisible, changed.sidebarVisible)
  }
}
