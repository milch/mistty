import XCTest
@testable import MisttyShared

final class RestoreConfigTests: XCTestCase {
  func test_resolve_returnsNilWhenNoRuleMatches() {
    let config = RestoreConfig(commands: [.init(match: "nvim", strategy: nil)])
    let captured = CapturedProcess(executable: "htop", argv: ["htop"])
    XCTAssertNil(config.resolve(captured))
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
}
