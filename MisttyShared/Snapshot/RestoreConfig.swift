public struct RestoreCommandRule: Codable, Sendable, Equatable {
  /// Exact match against the foreground process's executable basename.
  public var match: String
  /// Command string to run on restore. `nil` (or empty) ⇒ replay captured argv.
  public var strategy: String?
  /// Environment variables to set when running the restored command.
  /// Values support `{{pid}}` substitution. Emitted as an `env K=V …` prefix
  /// so it works across shells. Empty by default.
  public var env: [String: String]

  public init(match: String, strategy: String? = nil, env: [String: String] = [:]) {
    self.match = match
    self.strategy = strategy
    self.env = env
  }

  // Manual decoder so existing snapshots / configs that don't carry `env`
  // still decode (default to empty).
  private enum CodingKeys: String, CodingKey { case match, strategy, env }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    match = try c.decode(String.self, forKey: .match)
    strategy = try c.decodeIfPresent(String.self, forKey: .strategy)
    env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
  }
}

public struct RestoreConfig: Codable, Sendable, Equatable {
  public var commands: [RestoreCommandRule]

  public init(commands: [RestoreCommandRule] = []) {
    self.commands = commands
  }

  /// Executables that always restore via argv replay even without an
  /// explicit allowlist entry. These are Mistty session primitives where
  /// requiring the user to opt in would be worse UX than the tradeoff of
  /// a surprise relaunch. Users can still override by adding their own
  /// rule with a `strategy` (e.g. `strategy = "ssh -v"`).
  static let builtinAutoRestore: Set<String> = ["ssh"]

  /// Resolve a captured foreground process to a command string. Returns `nil`
  /// when no allowlist rule matches and the executable isn't in the built-in
  /// auto-restore set (caller should restore a bare shell).
  public func resolve(_ captured: CapturedProcess) -> String? {
    if let rule = commands.first(where: { $0.match == captured.executable }) {
      let base: String
      if let strategy = rule.strategy, !strategy.isEmpty {
        base = Self.substitute(strategy, captured: captured)
      } else {
        base = Self.shellJoin(captured.argv)
      }
      return Self.applyEnv(rule.env, to: base, captured: captured)
    }
    if Self.builtinAutoRestore.contains(captured.executable) {
      return Self.shellJoin(captured.argv)
    }
    return nil
  }

  /// Prepend `env K=V …` if the rule declared any env vars. Values run through
  /// the same `{{pid}}`-substitution as `strategy`, then get POSIX
  /// single-quoted so arbitrary characters survive the shell. Keys are sorted
  /// for deterministic output (matters for tests and config round-tripping).
  /// Returns `base` unchanged when env is empty.
  private static func applyEnv(
    _ env: [String: String], to base: String, captured: CapturedProcess
  ) -> String {
    guard !env.isEmpty else { return base }
    let pairs = env.keys.sorted().map { key -> String in
      let value = substitute(env[key] ?? "", captured: captured)
      return "\(key)=\(shellQuote(value))"
    }
    return "env \(pairs.joined(separator: " ")) \(base)"
  }

  private static func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy(isSafeShellChar) { return s }
    let escaped = s.replacingOccurrences(of: "'", with: #"'\''"#)
    return "'\(escaped)'"
  }

  /// Replace `{{pid}}` in a user-supplied strategy with the captured PID from
  /// save time. Useful when a program writes per-instance state keyed by its
  /// own PID (e.g. `:mksession! $PID.vim` in nvim) — the substituted strategy
  /// reloads the exact file the saved instance wrote. When no PID was captured
  /// (older snapshots, or capture failed) the token is left intact so the
  /// failure is visible instead of silently restoring the wrong state.
  private static func substitute(_ strategy: String, captured: CapturedProcess) -> String {
    guard strategy.contains("{{pid}}"), let pid = captured.pid else { return strategy }
    return strategy.replacingOccurrences(of: "{{pid}}", with: String(pid))
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
  /// PID at save time. Surfaces to strategies as `{{pid}}` so users can key
  /// per-instance state files on PID (e.g. `:mksession! $PID.vim`). Optional
  /// so snapshots saved before this field existed still decode.
  public var pid: Int32?

  public init(executable: String, argv: [String], pid: Int32? = nil) {
    self.executable = executable
    self.argv = argv
    self.pid = pid
  }
}
