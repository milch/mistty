import XCTest
@testable import MisttyShared

final class RestoreConfigTests: XCTestCase {
  func test_resolve_returnsNilWhenNoRuleMatches() {
    let config = RestoreConfig(commands: [.init(match: "nvim", strategy: nil)])
    let captured = CapturedProcess(executable: "htop", argv: ["htop"])
    XCTAssertNil(config.resolve(captured))
  }

  // ssh is in `builtinAutoRestore` so it survives a restore without the
  // user having to configure anything — ssh is a session primitive, not an
  // opt-in convenience like nvim.
  func test_resolve_sshAutoRestoresWithoutRuleWhenAllowlistEmpty() {
    let config = RestoreConfig()
    let captured = CapturedProcess(executable: "ssh", argv: ["ssh", "user@host"])
    XCTAssertEqual(config.resolve(captured), "ssh user@host")
  }

  func test_resolve_sshAutoRestoresWithoutRuleWhenOtherRulesPresent() {
    let config = RestoreConfig(commands: [.init(match: "nvim", strategy: nil)])
    let captured = CapturedProcess(executable: "ssh", argv: ["ssh", "user@host"])
    XCTAssertEqual(config.resolve(captured), "ssh user@host")
  }

  // Explicit user rule for ssh wins over the built-in replay — e.g. for
  // users who want to reconnect with extra flags.
  func test_resolve_sshUserRuleOverridesBuiltin() {
    let config = RestoreConfig(commands: [
      .init(match: "ssh", strategy: "ssh -v -o ServerAliveInterval=30"),
    ])
    let captured = CapturedProcess(executable: "ssh", argv: ["ssh", "user@host"])
    XCTAssertEqual(
      config.resolve(captured), "ssh -v -o ServerAliveInterval=30")
  }

  func test_resolve_returnsStrategyWhenRuleHasOne() {
    let config = RestoreConfig(commands: [.init(match: "claude", strategy: "claude --resume")])
    let captured = CapturedProcess(executable: "claude", argv: ["claude", "session-1"])
    XCTAssertEqual(config.resolve(captured), "claude --resume")
  }

  func test_resolve_replaysArgvWhenStrategyAbsent() {
    let config = RestoreConfig(commands: [.init(match: "nvim", strategy: nil)])
    let captured = CapturedProcess(executable: "nvim", argv: ["nvim", "mytext.txt"])
    XCTAssertEqual(config.resolve(captured), "nvim mytext.txt")
  }

  func test_resolve_shellQuotesArgvElementsWithSpaces() {
    let config = RestoreConfig(commands: [.init(match: "less", strategy: nil)])
    let captured = CapturedProcess(executable: "less", argv: ["less", "my file.log"])
    XCTAssertEqual(config.resolve(captured), "less 'my file.log'")
  }

  func test_resolve_shellQuotesArgvElementsWithSingleQuotes() {
    let config = RestoreConfig(commands: [.init(match: "echo", strategy: nil)])
    let captured = CapturedProcess(executable: "echo", argv: ["echo", "it's fine"])
    XCTAssertEqual(config.resolve(captured), #"echo 'it'\''s fine'"#)
  }

  func test_resolve_firstMatchWins() {
    let config = RestoreConfig(commands: [
      .init(match: "ssh", strategy: "ssh --quiet"),
      .init(match: "ssh", strategy: "ssh -v"),
    ])
    let captured = CapturedProcess(executable: "ssh", argv: ["ssh", "host"])
    XCTAssertEqual(config.resolve(captured), "ssh --quiet")
  }

  func test_resolve_emptyStrategyReplaysArgv() {
    let config = RestoreConfig(commands: [.init(match: "vim", strategy: "")])
    let captured = CapturedProcess(executable: "vim", argv: ["vim", "foo"])
    XCTAssertEqual(config.resolve(captured), "vim foo")
  }

  func test_resolve_emptyArgvProducesEmptyString() {
    let config = RestoreConfig(commands: [.init(match: "broken", strategy: nil)])
    let captured = CapturedProcess(executable: "broken", argv: [])
    XCTAssertEqual(config.resolve(captured), "")
  }

  func test_resolve_substitutesPidTokenInStrategy() {
    let config = RestoreConfig(commands: [
      .init(match: "nvim", strategy: "nvim -S {{pid}}.vim"),
    ])
    let captured = CapturedProcess(executable: "nvim", argv: ["nvim"], pid: 4321)
    XCTAssertEqual(config.resolve(captured), "nvim -S 4321.vim")
  }

  func test_resolve_substitutesMultiplePidTokens() {
    let config = RestoreConfig(commands: [
      .init(match: "tmux", strategy: "tmux new -s {{pid}} \\; source ~/.tmux/{{pid}}.conf"),
    ])
    let captured = CapturedProcess(executable: "tmux", argv: ["tmux"], pid: 99)
    XCTAssertEqual(
      config.resolve(captured),
      "tmux new -s 99 \\; source ~/.tmux/99.conf")
  }

  // Strategy containing `{{pid}}` but no captured PID (older snapshot, or
  // capture failed) — leave the token intact so the broken restore is
  // immediately visible to the user rather than silently restoring the
  // wrong state or a sibling-named file.
  func test_resolve_leavesPidTokenIntactWhenPidMissing() {
    let config = RestoreConfig(commands: [
      .init(match: "nvim", strategy: "nvim -S {{pid}}.vim"),
    ])
    let captured = CapturedProcess(executable: "nvim", argv: ["nvim"], pid: nil)
    XCTAssertEqual(config.resolve(captured), "nvim -S {{pid}}.vim")
  }

  func test_resolve_prependsEnvWhenRuleDeclaresIt() {
    let config = RestoreConfig(commands: [
      .init(match: "nvim", strategy: "nvim",
            env: ["NVIM_RESTORE_FROM_PID": "{{pid}}"]),
    ])
    let captured = CapturedProcess(executable: "nvim", argv: ["nvim"], pid: 4321)
    XCTAssertEqual(
      config.resolve(captured),
      "env NVIM_RESTORE_FROM_PID=4321 nvim")
  }

  // Keys are emitted in sorted order so tests (and config round-trips) are
  // deterministic across dictionary hash-order churn.
  func test_resolve_emitsEnvKeysInSortedOrder() {
    let config = RestoreConfig(commands: [
      .init(match: "nvim", strategy: "nvim",
            env: ["ZED": "last", "ALPHA": "first", "MIDDLE": "mid"]),
    ])
    let captured = CapturedProcess(executable: "nvim", argv: ["nvim"], pid: 1)
    XCTAssertEqual(
      config.resolve(captured),
      "env ALPHA=first MIDDLE=mid ZED=last nvim")
  }

  func test_resolve_shellQuotesEnvValuesWithSpecialChars() {
    let config = RestoreConfig(commands: [
      .init(match: "claude", strategy: "claude",
            env: ["SESSION": "my session"]),
    ])
    let captured = CapturedProcess(executable: "claude", argv: ["claude"], pid: 1)
    XCTAssertEqual(
      config.resolve(captured),
      "env SESSION='my session' claude")
  }

  func test_resolve_shellQuotesEmptyEnvValue() {
    let config = RestoreConfig(commands: [
      .init(match: "app", strategy: "app", env: ["FLAG": ""]),
    ])
    let captured = CapturedProcess(executable: "app", argv: ["app"], pid: 1)
    XCTAssertEqual(config.resolve(captured), "env FLAG='' app")
  }

  // No explicit strategy — env is applied on top of argv replay.
  func test_resolve_prependsEnvToArgvReplay() {
    let config = RestoreConfig(commands: [
      .init(match: "nvim", strategy: nil,
            env: ["NVIM_RESTORE_FROM_PID": "{{pid}}"]),
    ])
    let captured = CapturedProcess(
      executable: "nvim", argv: ["nvim", "foo.txt"], pid: 777)
    XCTAssertEqual(
      config.resolve(captured),
      "env NVIM_RESTORE_FROM_PID=777 nvim foo.txt")
  }

  // `env K=V cmd` doesn't compose with shell operators in `strategy` — the
  // shell parses `env K=V foo && bar` as `(env K=V foo) && (bar)`, so K
  // only reaches foo. That's documented on `RestoreCommandRule.env`; this
  // test pins the current behavior so a future change that silently wraps
  // in `sh -c` (changing the visible command in the terminal) doesn't slip
  // through unnoticed.
  func test_resolve_doesNotWrapStrategyWithShellOperators() {
    let config = RestoreConfig(commands: [
      .init(match: "app", strategy: "foo && bar", env: ["K": "V"]),
    ])
    let captured = CapturedProcess(executable: "app", argv: ["app"], pid: 1)
    XCTAssertEqual(config.resolve(captured), "env K=V foo && bar")
  }

  // Rules saved before the `env` field existed should decode with env = [:].
  func test_restoreCommandRule_decodesLegacyConfigWithoutEnv() throws {
    let legacyJSON = #"""
    {"match":"nvim","strategy":"nvim -S {{pid}}.vim"}
    """#
    let decoded = try JSONDecoder().decode(
      RestoreCommandRule.self, from: Data(legacyJSON.utf8))
    XCTAssertEqual(decoded.match, "nvim")
    XCTAssertEqual(decoded.strategy, "nvim -S {{pid}}.vim")
    XCTAssertEqual(decoded.env, [:])
  }

  // Snapshots saved before the `pid` field existed should still decode and
  // resolve correctly when the strategy doesn't use the token.
  func test_capturedProcess_decodesLegacySnapshotWithoutPid() throws {
    let legacyJSON = #"""
    {"executable":"nvim","argv":["nvim","foo.txt"]}
    """#
    let decoded = try JSONDecoder().decode(
      CapturedProcess.self, from: Data(legacyJSON.utf8))
    XCTAssertEqual(decoded.executable, "nvim")
    XCTAssertEqual(decoded.argv, ["nvim", "foo.txt"])
    XCTAssertNil(decoded.pid)
  }
}
