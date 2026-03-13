import Foundation
import TOMLKit

struct MisttyConfig: Sendable, Equatable {
  var fontSize: Int = 13
  var fontFamily: String = "monospace"
  var cursorStyle: String = "block"
  var scrollbackLines: Int = 10000
  var sidebarVisible: Bool = true

  static let `default` = MisttyConfig()

  static func parse(_ toml: String) throws -> MisttyConfig {
    let table = try TOMLTable(string: toml)
    var config = MisttyConfig()
    if let size = table["font_size"]?.int { config.fontSize = size }
    if let family = table["font_family"]?.string { config.fontFamily = family }
    if let cursor = table["cursor_style"]?.string { config.cursorStyle = cursor }
    if let scrollback = table["scrollback_lines"]?.int { config.scrollbackLines = scrollback }
    if let sidebar = table["sidebar_visible"]?.bool { config.sidebarVisible = sidebar }
    return config
  }

  static func load() -> MisttyConfig {
    let configURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(".config/mistty/config.toml")
    guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
      return .default
    }
    return (try? parse(contents)) ?? .default
  }

  func save() throws {
    let configURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(".config/mistty/config.toml")

    try FileManager.default.createDirectory(
      at: configURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var lines: [String] = []
    lines.append("font_size = \(fontSize)")
    lines.append("font_family = \"\(fontFamily)\"")
    lines.append("cursor_style = \"\(cursorStyle)\"")
    lines.append("scrollback_lines = \(scrollbackLines)")
    lines.append("sidebar_visible = \(sidebarVisible)")
    try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
  }
}
