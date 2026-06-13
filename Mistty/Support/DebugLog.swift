import Foundation

/// File-based debug logger, gated on `MisttyConfig.debugLogging`. Writes
/// timestamped lines to `~/Library/Logs/Mistty/mistty-debug.log`; no-op when
/// disabled. Use for instrumenting bugs that need longitudinal data to
/// diagnose (e.g. tracked-window drift, focus-loss races).
@MainActor
final class DebugLog {
  static let shared = DebugLog()

  private(set) var isEnabled: Bool = false

  /// Kept open across appends — opening/seeking/closing a FileHandle per
  /// log line is 4+ syscalls each, on the main actor. Reset to nil on a
  /// write error so the next append re-opens (e.g. log file deleted).
  private var handle: FileHandle?

  private let logURL: URL = {
    let logs = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Mistty", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: logs, withIntermediateDirectories: true)
    return logs.appendingPathComponent("mistty-debug.log")
  }()

  private let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private init() {}

  /// Path exposed so Settings can show it / offer a "Reveal in Finder" action.
  var logFilePath: String { logURL.path }

  func configure(enabled: Bool) {
    let wasEnabled = isEnabled
    isEnabled = enabled
    if enabled && !wasEnabled {
      append("=== debug logging enabled (session start) ===")
    }
  }

  func log(_ category: String, _ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let line = "\(formatter.string(from: Date())) [\(category)] \(message())"
    append(line)
  }

  private func append(_ raw: String) {
    var line = raw
    if !line.hasSuffix("\n") { line += "\n" }
    guard let data = line.data(using: .utf8) else { return }
    if handle == nil {
      if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
      }
      handle = try? FileHandle(forWritingTo: logURL)
      _ = try? handle?.seekToEnd()
    }
    guard let handle else { return }
    do {
      try handle.write(contentsOf: data)
    } catch {
      // Underlying file vanished or fd went bad — drop the handle so the
      // next append re-creates and re-opens.
      try? handle.close()
      self.handle = nil
    }
  }
}
