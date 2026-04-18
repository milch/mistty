import ArgumentParser
import Foundation
import MisttyShared

struct ConfigCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Inspect Mistty's ghostty configuration",
    subcommands: [Show.self]
  )

  struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Print the resolved ghostty config lines Mistty would pass to libghostty, in load order."
    )

    @Option(name: .long, help: "Path to config.toml (defaults to ~/.config/mistty/config.toml)")
    var configPath: String?

    func run() throws {
      let url: URL
      if let p = configPath {
        url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
      } else {
        url = GhosttyResolvedConfig.defaultConfigURL
      }

      let (resolved, parseError) = GhosttyResolvedConfig.load(from: url)
      if let parseError {
        FileHandle.standardError.write(
          Data("error: failed to parse \(url.path): \(describeTOMLParseError(parseError))\n".utf8))
        Foundation.exit(1)
      }

      let lines = resolved.configLines
      if lines.isEmpty {
        FileHandle.standardError.write(
          Data("# no Mistty-managed ghostty keys set in \(url.path)\n".utf8))
        return
      }
      for line in lines { print(line) }
    }
  }
}
