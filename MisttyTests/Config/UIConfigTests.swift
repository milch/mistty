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

  func test_toggle_fromHidden_goesAuto() {
    XCTAssertEqual(TabBarVisibilityOverride.hidden.toggled(configuredShow: true), .auto)
    XCTAssertEqual(TabBarVisibilityOverride.hidden.toggled(configuredShow: false), .auto)
  }

  func test_toggle_fromVisible_goesAuto() {
    XCTAssertEqual(TabBarVisibilityOverride.visible.toggled(configuredShow: true), .auto)
    XCTAssertEqual(TabBarVisibilityOverride.visible.toggled(configuredShow: false), .auto)
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

  func test_parseUIConfig_paneBorder() throws {
    let toml = """
      [ui]
      pane_border_color = "#3a3a3a"
      pane_border_width = 2
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ui.paneBorderColorHex, "#3a3a3a")
    XCTAssertEqual(config.ui.paneBorderWidth, 2)
  }

  func test_parseUIConfig_paneBorder_invalidHexIgnored() throws {
    let toml = """
      [ui]
      pane_border_color = "not-a-color"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertNil(config.ui.paneBorderColorHex)
  }

  func test_parseUIConfig_paneBorder_negativeWidthIgnored() throws {
    let toml = """
      [ui]
      pane_border_width = -3
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ui.paneBorderWidth, UIConfig().paneBorderWidth)
  }

  // MARK: Ghostty passthrough

  func test_ghosttyPassthrough_scalars() throws {
    let toml = """
      [ghostty]
      theme = "Dracula"
      mouse-hide-while-typing = true
      minimum-contrast = 2
      cursor-opacity = 0.9
      """
    let config = try MisttyConfig.parse(toml)
    // `theme` is emitted first so later overrides win; remaining keys follow
    // the underlying table's alphabetical order.
    XCTAssertEqual(
      config.ghostty.configLines,
      [
        "theme = Dracula",
        "cursor-opacity = 0.9",
        "minimum-contrast = 2",
        "mouse-hide-while-typing = true",
      ]
    )
  }

  func test_ghosttyPassthrough_arrays_expandToMultipleLines() throws {
    let toml = """
      [ghostty]
      font-family = ["JetBrainsMono Nerd Font", "SF Mono"]
      palette = ["0=#45475a", "1=#f38ba8"]
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(
      config.ghostty.configLines,
      [
        "font-family = JetBrainsMono Nerd Font",
        "font-family = SF Mono",
        "palette = 0=#45475a",
        "palette = 1=#f38ba8",
      ]
    )
  }

  func test_ghosttyPassthrough_deniedKeys_areDropped() throws {
    let toml = """
      [ghostty]
      theme = "Dracula"
      keybind = "cmd+shift+a=new_window"
      key-remap = "a=b"
      window-decoration = "none"
      macos-titlebar-style = "hidden"
      window-padding-x = 4
      background-opacity = 0.9
      background-blur = 20
      command = "zsh"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ghostty.configLines, ["theme = Dracula"])
  }

  func test_ghosttyConfigLines_mergesTopLevelFontAndPadding() throws {
    let toml = """
      font_size = 15
      font_family = "JetBrainsMono Nerd Font"
      cursor_style = "bar"
      scrollback_lines = 20000

      [ui]
      content_padding_x = [4, 8]

      [ghostty]
      theme = "Dracula"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(
      config.ghosttyConfigLines,
      [
        "window-theme = system",
        "font-size = 15",
        "font-family = JetBrainsMono Nerd Font",
        "cursor-style = bar",
        "scrollback-limit = \(20000 * 1000)",
        "theme = Dracula",
        "window-padding-x = 4,8",
      ]
    )
  }

  func test_ghosttyConfigLines_prependsWindowThemeSystemWhenAnyKeySet() throws {
    // Ghostty picks between `light:` / `dark:` variants of multi-theme
    // strings based on `window-theme`. Mistty forces it to follow macOS
    // appearance whenever there's anything to emit.
    let config = try MisttyConfig.parse("font_size = 14")
    XCTAssertEqual(
      config.ghosttyConfigLines,
      ["window-theme = system", "font-size = 14"]
    )
  }

  func test_ghosttyConfigLines_emptyWhenNothingSet() throws {
    // Don't write a temp config with `window-theme = system` and nothing
    // else — it adds IO for zero user-visible effect.
    let config = try MisttyConfig.parse("")
    XCTAssertTrue(config.ghosttyConfigLines.isEmpty)
  }

  func test_ghosttyConfigLines_userCanOverrideWindowTheme() throws {
    let toml = """
      [ghostty]
      window-theme = "light"
      """
    let config = try MisttyConfig.parse(toml)
    // User override supersedes the default; Mistty doesn't emit the default
    // anymore when `window-theme` is user-controlled.
    XCTAssertEqual(config.ghosttyConfigLines, ["window-theme = light"])
  }

  func test_ghosttyConfigLines_emptyFontFamilyDoesNotEmitReset() throws {
    // An empty `font_family` string would translate to `font-family = `
    // which ghostty interprets as "clear the font-family list" — almost
    // certainly not what a user leaving the field blank intends. Skip the
    // forward entirely and let ghostty's own default apply.
    let toml = """
      font_family = ""
      cursor_style = "block"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(
      config.ghosttyConfigLines,
      ["window-theme = system", "cursor-style = block"]
    )
  }

  func test_ghosttyPassthrough_preservesTomlTypeAcrossSaveRoundTrip() throws {
    // String-that-looks-like-a-bool / string-that-looks-like-a-number must
    // survive save() without being coerced to the wrong TOML type. Reviewer
    // flagged this as the top bug in the previous implementation.
    let toml = """
      [ghostty]
      term = "true"
      enquiry-response = "123"
      cursor-opacity = 0.9
      mouse-hide-while-typing = true
      """
    let parsed = try MisttyConfig.parse(toml)
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-config-roundtrip-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tempURL) }
    try parsed.save(to: tempURL)

    let reParsed = try MisttyConfig.parse(
      String(contentsOf: tempURL, encoding: .utf8))
    XCTAssertEqual(parsed.ghostty, reParsed.ghostty)
    // Explicitly verify the types weren't coerced.
    let termEntry = reParsed.ghostty.entries.first { $0.key == "term" }
    XCTAssertEqual(termEntry?.kind, .string)
    XCTAssertEqual(termEntry?.value, "true")
    let enquiryEntry = reParsed.ghostty.entries.first { $0.key == "enquiry-response" }
    XCTAssertEqual(enquiryEntry?.kind, .string)
    XCTAssertEqual(enquiryEntry?.value, "123")
    let opacityEntry = reParsed.ghostty.entries.first { $0.key == "cursor-opacity" }
    XCTAssertEqual(opacityEntry?.kind, .double)
  }

  func test_loadThrowing_reportsParseErrors() throws {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-config-bad-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tempURL) }
    try "this is not valid = toml = at = all\n".write(
      to: tempURL, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try MisttyConfig.loadThrowing(from: tempURL))
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
