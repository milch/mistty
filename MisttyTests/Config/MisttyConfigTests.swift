import XCTest

@testable import Mistty

final class MisttyConfigTests: XCTestCase {
  func test_defaultConfig() {
    let config = MisttyConfig.default
    XCTAssertEqual(config.fontSize, 13)
    XCTAssertEqual(config.fontFamily, "monospace")
  }

  func test_parsesValidTOML() throws {
    let toml = """
      font_size = 16
      font_family = "JetBrains Mono"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.fontSize, 16)
    XCTAssertEqual(config.fontFamily, "JetBrains Mono")
  }

  func test_missingKeysUseDefaults() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertEqual(config.fontSize, 13)
    XCTAssertEqual(config.fontFamily, "monospace")
  }

  func test_invalidTOMLThrows() {
    XCTAssertThrowsError(try MisttyConfig.parse("font_size = !!!invalid"))
  }

  func test_parsesPopupDefinitions() throws {
    let toml = """
      [[popup]]
      name = "lazygit"
      command = "lazygit"
      shortcut = "cmd+shift+g"
      width = 0.8
      height = 0.8
      close_on_exit = true

      [[popup]]
      name = "btop"
      command = "btop"
      width = 0.9
      height = 0.9
      close_on_exit = false
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.popups.count, 2)
    XCTAssertEqual(config.popups[0].name, "lazygit")
    XCTAssertEqual(config.popups[0].command, "lazygit")
    XCTAssertEqual(config.popups[0].shortcut, "cmd+shift+g")
    XCTAssertEqual(config.popups[0].width, 0.8)
    XCTAssertEqual(config.popups[0].height, 0.8)
    XCTAssertEqual(config.popups[0].closeOnExit, true)
    XCTAssertEqual(config.popups[1].name, "btop")
    XCTAssertEqual(config.popups[1].shortcut, nil)
    XCTAssertEqual(config.popups[1].closeOnExit, false)
  }

  func test_noPopupsReturnsEmptyArray() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertEqual(config.popups.count, 0)
  }

  func test_popupDefaultValues() throws {
    let toml = """
      [[popup]]
      name = "test"
      command = "test"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.popups[0].width, 0.8)
    XCTAssertEqual(config.popups[0].height, 0.8)
    XCTAssertEqual(config.popups[0].closeOnExit, true)
    XCTAssertEqual(config.popups[0].shortcut, nil)
  }
}
