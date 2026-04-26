import XCTest
import MisttyShared

@testable import Mistty

final class MisttyConfigTests: XCTestCase {
  func test_defaultConfig() {
    // Top-level ghostty passthrough keys store `nil` by default so that
    // nothing is emitted to ghostty unless the user explicitly asks.
    // Settings UI surfaces the display defaults via `resolvedXxx`.
    let config = MisttyConfig.default
    XCTAssertNil(config.fontSize)
    XCTAssertNil(config.fontFamily)
    XCTAssertEqual(config.resolvedFontSize, MisttyConfig.defaultFontSize)
    XCTAssertEqual(config.resolvedFontFamily, MisttyConfig.defaultFontFamily)
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
    XCTAssertNil(config.fontSize)
    XCTAssertNil(config.fontFamily)
    XCTAssertEqual(config.resolvedFontSize, MisttyConfig.defaultFontSize)
    XCTAssertEqual(config.resolvedFontFamily, MisttyConfig.defaultFontFamily)
  }

  func test_invalidTOMLThrows() {
    XCTAssertThrowsError(try MisttyConfig.parse("font_size = !!!invalid"))
  }

  func test_zoxidePath_unsetByDefault() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertNil(config.zoxidePath)
  }

  func test_zoxidePath_absolute() throws {
    let config = try MisttyConfig.parse(#"zoxide_path = "/opt/homebrew/bin/zoxide""#)
    XCTAssertEqual(config.zoxidePath, "/opt/homebrew/bin/zoxide")
  }

  func test_zoxidePath_expandsTilde() throws {
    let config = try MisttyConfig.parse(#"zoxide_path = "~/.cargo/bin/zoxide""#)
    XCTAssertEqual(config.zoxidePath, NSHomeDirectory() + "/.cargo/bin/zoxide")
  }

  func test_zoxidePath_emptyStringTreatedAsUnset() throws {
    let config = try MisttyConfig.parse(#"zoxide_path = """#)
    XCTAssertNil(config.zoxidePath)
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

  func test_parse_restoreCommand_emptyByDefault() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertEqual(config.restore, RestoreConfig())
  }

  func test_parse_restoreCommand_singleRuleWithoutStrategy() throws {
    let toml = """
    [[restore.command]]
    match = "nvim"
    """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.restore.commands, [.init(match: "nvim", strategy: nil)])
  }

  func test_parse_restoreCommand_multipleRulesPreserveOrder() throws {
    let toml = """
    [[restore.command]]
    match = "claude"
    strategy = "claude --resume"

    [[restore.command]]
    match = "nvim"
    """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.restore.commands, [
      .init(match: "claude", strategy: "claude --resume"),
      .init(match: "nvim", strategy: nil),
    ])
  }

  func test_save_restoreCommand_roundTrip() throws {
    var config = MisttyConfig()
    config.restore = RestoreConfig(commands: [
      .init(match: "nvim", strategy: nil),
      .init(match: "claude", strategy: "claude --resume"),
    ])
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-restore-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.restore, config.restore)
  }

  func test_parse_restoreCommand_withEnv() throws {
    let toml = """
    [[restore.command]]
    match = "nvim"
    strategy = "nvim"
    env = { NVIM_RESTORE_FROM_PID = "{{pid}}", FOO = "bar baz" }
    """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.restore.commands, [
      .init(match: "nvim", strategy: "nvim",
            env: ["NVIM_RESTORE_FROM_PID": "{{pid}}", "FOO": "bar baz"]),
    ])
  }

  // Users can write scalar non-string values in TOML env tables; we coerce
  // them rather than silently dropping. Matches the principle-of-least-
  // astonishment for a config field that's meant to be "set these env vars."
  func test_parse_restoreCommand_coercesScalarEnvValues() throws {
    let toml = """
    [[restore.command]]
    match = "app"
    env = { PORT = 8080, RATE = 0.5, DEBUG = true, NAME = "explicit" }
    """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.restore.commands, [
      .init(match: "app", strategy: nil, env: [
        "PORT": "8080", "RATE": "0.5", "DEBUG": "true", "NAME": "explicit",
      ]),
    ])
  }

  func test_save_restoreCommand_withEnv_roundTrip() throws {
    var config = MisttyConfig()
    config.restore = RestoreConfig(commands: [
      .init(match: "nvim", strategy: "nvim",
            env: ["NVIM_RESTORE_FROM_PID": "{{pid}}", "FOO": "bar baz"]),
    ])
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-restore-env-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.restore, config.restore)
  }

  func test_reload_swapsCurrent_onSuccess() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-reload-\(UUID().uuidString).toml")
    try "font_size = 16\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let original = MisttyConfig.current
    defer { MisttyConfig.current = original }

    let observer = expectation(forNotification: .misttyConfigDidReload, object: nil)
    let result = try MisttyConfig.reload(from: url)
    wait(for: [observer], timeout: 1.0)

    XCTAssertEqual(result.fontSize, 16)
    XCTAssertEqual(MisttyConfig.current.fontSize, 16)
  }

  func test_reload_keepsCurrent_onParseError() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-reload-bad-\(UUID().uuidString).toml")
    try? "this is = not [valid toml\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    var snapshot = MisttyConfig()
    snapshot.fontSize = 42
    let original = MisttyConfig.current
    defer { MisttyConfig.current = original }
    MisttyConfig.current = snapshot

    XCTAssertThrowsError(try MisttyConfig.reload(from: url))
    XCTAssertEqual(MisttyConfig.current.fontSize, 42)
  }
}
