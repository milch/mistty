import TOMLKit
import Foundation

struct MisttyConfig: Sendable {
    var fontSize: Int = 13
    var fontFamily: String = "monospace"

    static let `default` = MisttyConfig()

    static func parse(_ toml: String) throws -> MisttyConfig {
        let table = try TOMLTable(string: toml)
        var config = MisttyConfig()
        if let size = table["font_size"]?.int { config.fontSize = size }
        if let family = table["font_family"]?.string { config.fontFamily = family }
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
}
