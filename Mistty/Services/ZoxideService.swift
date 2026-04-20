import Foundation

struct ZoxideService: Sendable {
  /// Common install locations for `zoxide` on macOS. Checked in order.
  /// GUI-launched apps (Dock/Finder/Launchpad) inherit a minimal `PATH` that
  /// excludes Homebrew and `~/.cargo/bin`, so `/usr/bin/env zoxide` fails.
  /// Probing explicit paths keeps the Session Manager working regardless of
  /// how Mistty was launched.
  static let candidatePaths: [String] = [
    "/opt/homebrew/bin/zoxide",  // Apple Silicon Homebrew
    "/usr/local/bin/zoxide",  // Intel Homebrew / manual install
    "/run/current-system/sw/bin/zoxide",  // nix-darwin system profile
    "/etc/profiles/per-user/\(NSUserName())/bin/zoxide",  // home-manager per-user
    "\(NSHomeDirectory())/.nix-profile/bin/zoxide",  // nix single-user
    "\(NSHomeDirectory())/.cargo/bin/zoxide",  // cargo install
    "\(NSHomeDirectory())/.local/bin/zoxide",  // pip/user installs
  ]

  /// Cached absolute path to `zoxide`, resolved on first use.
  private static let cachedExecutable = CachedExecutable()

  static func recentDirectories() async -> [URL] {
    guard let executable = await cachedExecutable.resolve() else { return [] }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["query", "-l"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""
      return
        output
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }
        .map { URL(fileURLWithPath: $0) }
    } catch {
      return []
    }
  }

  /// Resolves the absolute path to `zoxide` once per process. First tries the
  /// baked-in candidate list (cheap stat calls), then falls back to asking the
  /// user's login shell (`bash -lc 'command -v zoxide'`) which re-evaluates
  /// the user's shell init files and picks up custom install locations.
  private actor CachedExecutable {
    private var resolved: String??

    func resolve() -> String? {
      if let resolved { return resolved }
      let path = Self.locate()
      resolved = .some(path)
      return path
    }

    private static func locate() -> String? {
      let fm = FileManager.default
      for candidate in ZoxideService.candidatePaths where fm.isExecutableFile(atPath: candidate) {
        return candidate
      }
      return locateViaLoginShell()
    }

    private static func locateViaLoginShell() -> String? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = ["-lc", "command -v zoxide"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()

      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        return nil
      }

      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) else {
        return nil
      }
      return output
    }
  }
}
