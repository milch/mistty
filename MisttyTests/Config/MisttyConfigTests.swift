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

  func test_parsesSSHConfig() throws {
    let toml = """
      [ssh]
      default_command = "et"

      [[ssh.host]]
      hostname = "dev-box"
      command = "et"

      [[ssh.host]]
      regex = "prod-.*"
      command = "ssh"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ssh.defaultCommand, "et")
    XCTAssertEqual(config.ssh.hosts.count, 2)
    XCTAssertEqual(config.ssh.hosts[0].hostname, "dev-box")
    XCTAssertNil(config.ssh.hosts[0].regex)
    XCTAssertEqual(config.ssh.hosts[0].command, "et")
    XCTAssertNil(config.ssh.hosts[1].hostname)
    XCTAssertEqual(config.ssh.hosts[1].regex, "prod-.*")
    XCTAssertEqual(config.ssh.hosts[1].command, "ssh")
  }

  func test_sshConfigDefaults() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertEqual(config.ssh.defaultCommand, "ssh")
    XCTAssertTrue(config.ssh.hosts.isEmpty)
  }

  func test_sshCommandResolution_exactMatch() throws {
    let toml = """
      [[ssh.host]]
      hostname = "dev-box"
      command = "et"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ssh.resolveCommand(for: "dev-box"), "et")
    XCTAssertEqual(config.ssh.resolveCommand(for: "other"), "ssh")
  }

  func test_sshCommandResolution_regexMatch() throws {
    let toml = """
      [[ssh.host]]
      regex = "prod-.*"
      command = "et"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ssh.resolveCommand(for: "prod-web1"), "et")
    XCTAssertEqual(config.ssh.resolveCommand(for: "staging-web1"), "ssh")
  }

  func test_sshCommandResolution_firstMatchWins() throws {
    let toml = """
      [[ssh.host]]
      hostname = "prod-db"
      command = "ssh"

      [[ssh.host]]
      regex = "prod-.*"
      command = "et"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.ssh.resolveCommand(for: "prod-db"), "ssh")
    XCTAssertEqual(config.ssh.resolveCommand(for: "prod-web"), "et")
  }
}
