import Foundation

struct ZoxideService: Sendable {
  static func recentDirectories() async -> [URL] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["zoxide", "query", "-l"]
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
}
