import XCTest

@testable import Mistty

final class UIConfigTests: XCTestCase {
  // MARK: TabBarMode.shouldShow

  func test_tabBarMode_always() {
    for sidebar in [true, false] {
      for tabCount in [1, 2, 5] {
        XCTAssertTrue(TabBarMode.always.shouldShow(sidebarVisible: sidebar, tabCount: tabCount))
      }
    }
  }

  func test_tabBarMode_never() {
    for sidebar in [true, false] {
      for tabCount in [1, 2, 5] {
        XCTAssertFalse(TabBarMode.never.shouldShow(sidebarVisible: sidebar, tabCount: tabCount))
      }
    }
  }

  func test_tabBarMode_whenSidebarHidden() {
    XCTAssertFalse(TabBarMode.whenSidebarHidden.shouldShow(sidebarVisible: true, tabCount: 1))
    XCTAssertFalse(TabBarMode.whenSidebarHidden.shouldShow(sidebarVisible: true, tabCount: 5))
    XCTAssertTrue(TabBarMode.whenSidebarHidden.shouldShow(sidebarVisible: false, tabCount: 1))
    XCTAssertTrue(TabBarMode.whenSidebarHidden.shouldShow(sidebarVisible: false, tabCount: 5))
  }

  func test_tabBarMode_whenSidebarHiddenAndMultipleTabs() {
    XCTAssertFalse(
      TabBarMode.whenSidebarHiddenAndMultipleTabs.shouldShow(sidebarVisible: true, tabCount: 1))
    XCTAssertFalse(
      TabBarMode.whenSidebarHiddenAndMultipleTabs.shouldShow(sidebarVisible: true, tabCount: 5))
    XCTAssertFalse(
      TabBarMode.whenSidebarHiddenAndMultipleTabs.shouldShow(sidebarVisible: false, tabCount: 1))
    XCTAssertTrue(
      TabBarMode.whenSidebarHiddenAndMultipleTabs.shouldShow(sidebarVisible: false, tabCount: 5))
  }

  func test_tabBarMode_whenMultipleTabs() {
    XCTAssertFalse(TabBarMode.whenMultipleTabs.shouldShow(sidebarVisible: true, tabCount: 1))
    XCTAssertTrue(TabBarMode.whenMultipleTabs.shouldShow(sidebarVisible: true, tabCount: 5))
    XCTAssertFalse(TabBarMode.whenMultipleTabs.shouldShow(sidebarVisible: false, tabCount: 1))
    XCTAssertTrue(TabBarMode.whenMultipleTabs.shouldShow(sidebarVisible: false, tabCount: 5))
  }

  // MARK: TitleBarStyle

  func test_titleBarStyle_always() {
    XCTAssertFalse(TitleBarStyle.always.hasTrafficLights)
    XCTAssertFalse(TitleBarStyle.always.contentExtendsUnderTitleBar)
    XCTAssertFalse(TitleBarStyle.always.shouldHideWindowButtons)
  }

  func test_titleBarStyle_hiddenWithLights() {
    XCTAssertTrue(TitleBarStyle.hiddenWithLights.hasTrafficLights)
    XCTAssertTrue(TitleBarStyle.hiddenWithLights.contentExtendsUnderTitleBar)
    XCTAssertFalse(TitleBarStyle.hiddenWithLights.shouldHideWindowButtons)
  }

  func test_titleBarStyle_hiddenNoLights() {
    XCTAssertFalse(TitleBarStyle.hiddenNoLights.hasTrafficLights)
    XCTAssertTrue(TitleBarStyle.hiddenNoLights.contentExtendsUnderTitleBar)
    XCTAssertTrue(TitleBarStyle.hiddenNoLights.shouldHideWindowButtons)
  }

  // MARK: TOML parsing

  func test_parseUIConfig_defaults() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertEqual(config.ui.tabBarMode, .whenMultipleTabs)
    XCTAssertEqual(config.ui.titleBarStyle, .hiddenWithLights)
  }

  func test_parseUIConfig_explicit() throws {
    let toml = """
      [ui]
      tab_bar_mode = "always"
      title_bar_style = "hidden_no_lights"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ui.tabBarMode, .always)
    XCTAssertEqual(config.ui.titleBarStyle, .hiddenNoLights)
  }

  func test_parseUIConfig_invalidValues_fallBackToDefault() throws {
    let toml = """
      [ui]
      tab_bar_mode = "garbage"
      title_bar_style = "also_bad"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ui.tabBarMode, .whenMultipleTabs)
    XCTAssertEqual(config.ui.titleBarStyle, .hiddenWithLights)
  }
}
