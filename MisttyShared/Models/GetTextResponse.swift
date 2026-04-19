import Foundation

public struct GetTextResponse: Codable, Sendable, PrintableByFormatter {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public static func formatHeader() -> [String] {
        ["Text"]
    }

    public func formatRow() -> [String] {
        [
            self.text
        ]
    }
}
