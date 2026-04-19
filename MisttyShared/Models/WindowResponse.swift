import Foundation

public struct WindowResponse: Codable, Sendable, PrintableByFormatter {
    public let id: Int
    public let sessionCount: Int

    public init(id: Int, sessionCount: Int) {
        self.id = id
        self.sessionCount = sessionCount
    }

    public static func formatHeader() -> [String] {
        [
            "ID",
            "Sessions",
        ]
    }

    public func formatRow() -> [String] {
        [
            "\(self.id)",
            "\(self.sessionCount)",
        ]
    }
}
