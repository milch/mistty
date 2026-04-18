import Foundation

public struct PaneResponse: Codable, Sendable, PrintableByFormatter {
    public let id: Int
    public let directory: String?

    public init(id: Int, directory: String?) {
        self.id = id
        self.directory = directory
    }

    public static func formatHeader() -> [String] {
        ["ID", "Directory"]
    }

    public func formatRow() -> [String] {
        [
            "\(self.id)",
            self.directory ?? "-",
        ]
    }
}
