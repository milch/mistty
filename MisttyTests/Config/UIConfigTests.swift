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

  // MARK: TabBarVisibilityOverride

  func test_override_auto_followsConfiguredShow() {
    XCTAssertTrue(TabBarVisibilityOverride.auto.effectiveShow(configuredShow: true))
    XCTAssertFalse(TabBarVisibilityOverride.auto.effectiveShow(configuredShow: false))
  }

  func test_override_hidden_alwaysHides() {
    XCTAssertFalse(TabBarVisibilityOverride.hidden.effectiveShow(configuredShow: true))
    XCTAssertFalse(TabBarVisibilityOverride.hidden.effectiveShow(configuredShow: false))
  }

  func test_override_visible_alwaysShows() {
    XCTAssertTrue(TabBarVisibilityOverride.visible.effectiveShow(configuredShow: true))
    XCTAssertTrue(TabBarVisibilityOverride.visible.effectiveShow(configuredShow: false))
  }

  func test_toggle_fromAuto_flipsConfiguredDefault() {
    // Configured show → user wants it hidden
    XCTAssertEqual(TabBarVisibilityOverride.auto.toggled(configuredShow: true), .hidden)
    // Configured hidden → user wants it visible
    XCTAssertEqual(TabBarVisibilityOverride.auto.toggled(configuredShow: false), .visible)
  }

  func test_toggle_fromHidden_goesVisible() {
    XCTAssertEqual(TabBarVisibilityOverride.hidden.toggled(configuredShow: true), .visible)
    XCTAssertEqual(TabBarVisibilityOverride.hidden.toggled(configuredShow: false), .visible)
  }

  func test_toggle_fromVisible_goesHidden() {
    XCTAssertEqual(TabBarVisibilityOverride.visible.toggled(configuredShow: true), .hidden)
    XCTAssertEqual(TabBarVisibilityOverride.visible.toggled(configuredShow: false), .hidden)
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

  func test_parseUIConfig_contentPadding_singleInt() throws {
    let toml = """
      [ui]
      content_padding_x = 4
      content_padding_y = 9
      content_padding_balance = true
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ui.contentPaddingX, [4])
    XCTAssertEqual(config.ui.contentPaddingY, [9])
    XCTAssertEqual(config.ui.contentPaddingBalance, true)
  }

  func test_parseUIConfig_contentPadding_arrayPair() throws {
    let toml = """
      [ui]
      content_padding_x = [4, 8]
      content_padding_y = [9, 0]
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ui.contentPaddingX, [4, 8])
    XCTAssertEqual(config.ui.contentPaddingY, [9, 0])
  }

  func test_ghosttyPaddingConfigLines_emitsGhosttyKeys() {
    var ui = UIConfig()
    ui.contentPaddingX = [4]
    ui.contentPaddingY = [9, 0]
    ui.contentPaddingBalance = true
    XCTAssertEqual(
      ui.ghosttyPaddingConfigLines,
      [
        "window-padding-x = 4",
        "window-padding-y = 9,0",
        "window-padding-balance = true",
      ]
    )
  }

  func test_ghosttyPaddingConfigLines_emptyWhenNothingSet() {
    XCTAssertTrue(UIConfig().ghosttyPaddingConfigLines.isEmpty)
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
