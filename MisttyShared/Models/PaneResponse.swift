import Foundation

public struct PaneResponse: Codable, Sendable, PrintableByFormatter {
    public let id: Int
    public let window: Int
    public let directory: String?

    public init(id: Int, window: Int, directory: String?) {
        self.id = id
        self.window = window
        self.directory = directory
    }

    public static func formatHeader() -> [String] {
        ["ID", "Window", "Directory"]
    }

    public func formatRow() -> [String] {
        [
            "\(self.id)",
            "\(self.window)",
            self.directory ?? "-",
        ]
    }
}
