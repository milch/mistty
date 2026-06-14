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
    XCTAssertEqual(config.popups[0].shortcutRaw, "cmd+shift+g")
    XCTAssertEqual(config.popups[0].width, 0.8)
    XCTAssertEqual(config.popups[0].height, 0.8)
    XCTAssertEqual(config.popups[0].closeOnExit, true)
    XCTAssertEqual(config.popups[1].name, "btop")
    XCTAssertEqual(config.popups[1].shortcutRaw, nil)
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
    XCTAssertEqual(config.popups[0].shortcutRaw, nil)
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

  /// popup.name / popup.command were interpolated into config.toml WITHOUT
  /// tomlEscape (unlike every sibling field) — a command containing a
  /// double quote (e.g. `sh -c "..."`) produced an unparseable file on the
  /// next Settings save, silently corrupting the user's config.
  func test_save_popupWithQuotesAndBackslashes_roundTrips() throws {
    var config = MisttyConfig()
    config.popups = [
      PopupDefinition(
        name: #"log "viewer""#,
        command: #"sh -c "tail -f /tmp/a.log | grep \"error\"""#)
    ]
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-popup-escape-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.popups, config.popups)
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
    XCTAssertNotNil(MisttyConfig.lastParseError)
  }

  func test_notifications_defaultEnabled() throws {
    let config = try MisttyConfig.parse("")
    XCTAssertTrue(config.notifications.enabled)
    XCTAssertFalse(config.notifications.explicitlyEnabled)
  }

  func test_notifications_explicitTrue() throws {
    let toml = """
      [notifications]
      enabled = true
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertTrue(config.notifications.enabled)
    XCTAssertTrue(config.notifications.explicitlyEnabled)
  }

  func test_notifications_explicitFalse() throws {
    let toml = """
      [notifications]
      enabled = false
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertFalse(config.notifications.enabled)
    XCTAssertFalse(config.notifications.explicitlyEnabled)
  }

  func test_notifications_emptyTableUsesDefaults() throws {
    let config = try MisttyConfig.parse("[notifications]")
    XCTAssertTrue(config.notifications.enabled)
    XCTAssertFalse(config.notifications.explicitlyEnabled)
  }

  func test_clipboardRead_defaultsToPrompt() {
    XCTAssertEqual(MisttyConfig().clipboardRead, .prompt)
  }

  func test_clipboardRead_parsesModeStrings() throws {
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = \"allow\"").clipboardRead, .allow)
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = \"prompt\"").clipboardRead, .prompt)
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = \"deny\"").clipboardRead, .deny)
  }

  func test_clipboardRead_migratesLegacyBool() throws {
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = true").clipboardRead, .allow)
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = false").clipboardRead, .deny)
  }

  func test_clipboardRead_unrecognizedFallsBackToPrompt() throws {
    XCTAssertEqual(try MisttyConfig.parse("allow_clipboard_read = \"bogus\"").clipboardRead, .prompt)
  }

  func test_clipboardRead_roundTrips() throws {
    for mode in [ClipboardReadMode.allow, .deny] {  // .prompt is the default → not emitted
      var config = MisttyConfig()
      config.clipboardRead = mode
      let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mistty-clipmode-\(UUID().uuidString).toml")
      defer { try? FileManager.default.removeItem(at: tmp) }
      try config.save(to: tmp)
      XCTAssertEqual(try MisttyConfig.loadThrowing(from: tmp).clipboardRead, mode)
    }
  }

  func test_clipboardProcessRules_parse() throws {
    let toml = """
      [[clipboard.process]]
      name = "nvim"
      allow_clipboard_read = "allow"

      [[clipboard.process]]
      name = "sketchytui"
      allow_clipboard_read = "deny"
      """
    let config = try MisttyConfig.parse(toml)
    XCTAssertEqual(config.clipboardProcessRules, [
      .init(name: "nvim", mode: .allow),
      .init(name: "sketchytui", mode: .deny),
    ])
  }

  func test_clipboardProcessRules_skipInvalidEntries() throws {
    let toml = """
      [[clipboard.process]]
      allow_clipboard_read = "allow"

      [[clipboard.process]]
      name = "x"
      allow_clipboard_read = "bogus"

      [[clipboard.process]]
      name = "nvim"
      allow_clipboard_read = "prompt"
      """
    // First missing name → skipped; second bad mode → skipped; third kept.
    XCTAssertEqual(try MisttyConfig.parse(toml).clipboardProcessRules,
                   [.init(name: "nvim", mode: .prompt)])
  }

  func test_clipboardProcessRule_lookup_firstMatchWins() {
    var config = MisttyConfig()
    config.clipboardProcessRules = [
      .init(name: "nvim", mode: .allow),
      .init(name: "nvim", mode: .deny),
    ]
    XCTAssertEqual(config.clipboardProcessRule(for: "nvim"), .allow)
    XCTAssertNil(config.clipboardProcessRule(for: "zsh"))
  }

  func test_settingClipboardProcessRule_upserts() {
    let base = MisttyConfig()
    let added = base.settingClipboardProcessRule(name: "nvim", mode: .allow)
    XCTAssertEqual(added.clipboardProcessRules, [.init(name: "nvim", mode: .allow)])
    let replaced = added.settingClipboardProcessRule(name: "nvim", mode: .deny)
    XCTAssertEqual(replaced.clipboardProcessRules, [.init(name: "nvim", mode: .deny)])
  }

  func test_clipboardProcessRules_roundTrip() throws {
    var config = MisttyConfig()
    config.clipboardProcessRules = [
      .init(name: "nvim", mode: .allow),
      .init(name: "sketchytui", mode: .deny),
    ]
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-cliprules-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    XCTAssertEqual(try MisttyConfig.loadThrowing(from: tmp).clipboardProcessRules,
                   config.clipboardProcessRules)
  }

  func test_save_notifications_roundTrip_explicitTrue() throws {
    var config = MisttyConfig()
    config.notifications = NotificationsConfig(enabled: true, explicitlyEnabled: true)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-notif-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.notifications, config.notifications)
  }

  func test_save_notifications_roundTrip_explicitFalse() throws {
    var config = MisttyConfig()
    config.notifications = NotificationsConfig(enabled: false, explicitlyEnabled: false)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-notif-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try config.save(to: tmp)
    let roundTripped = try MisttyConfig.loadThrowing(from: tmp)
    XCTAssertEqual(roundTripped.notifications, config.notifications)
  }
}
