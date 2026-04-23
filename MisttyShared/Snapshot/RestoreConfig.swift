public struct RestoreCommandRule: Codable, Sendable, Equatable {
  /// Exact match against the foreground process's executable basename.
  public var match: String
  /// Command string to run on restore. `nil` (or empty) ⇒ replay captured argv.
  public var strategy: String?

  public init(match: String, strategy: String? = nil) {
    self.match = match
    self.strategy = strategy
  }
}

public struct RestoreConfig: Codable, Sendable, Equatable {
  public var commands: [RestoreCommandRule]

  public init(commands: [RestoreCommandRule] = []) {
    self.commands = commands
  }

  /// Resolve a captured foreground process to a command string. Returns `nil`
  /// when no allowlist rule matches (caller should restore a bare shell).
  public func resolve(_ captured: CapturedProcess) -> String? {
    guard let rule = commands.first(where: { $0.match == captured.executable })
    else { return nil }
    if let strategy = rule.strategy, !strategy.isEmpty {
      return strategy
    }
    return Self.shellJoin(captured.argv)
  }

  /// POSIX single-quote escape any argv element that contains shell
  /// metacharacters; join with single spaces.
  private static func shellJoin(_ argv: [String]) -> String {
    argv.map { arg in
      if arg.allSatisfy(isSafeShellChar) { return arg }
      let escaped = arg.replacingOccurrences(of: "'", with: #"'\''"#)
      return "'\(escaped)'"
    }.joined(separator: " ")
  }

  private static func isSafeShellChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || "_-./:@,+=".contains(c)
  }
}

/// Captured at save time; stored in `PaneSnapshot.captured`. Strategy
/// resolution happens at RESTORE time so config edits take effect.
public struct CapturedProcess: Codable, Sendable, Equatable {
  /// Basename only — e.g. "nvim", not "/usr/local/bin/nvim".
  public var executable: String
  /// Full argument vector including argv[0].
  public var argv: [String]

  public init(executable: String, argv: [String]) {
    self.executable = executable
    self.argv = argv
  }
}
