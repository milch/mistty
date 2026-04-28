import Foundation

public struct SessionResponse: Codable, Sendable, PrintableByFormatter {
    public let id: Int
    public let window: Int
    public let name: String
    public let directory: String
    public let tabCount: Int
    public let tabIds: [Int]

    public init(id: Int, window: Int, name: String, directory: String, tabCount: Int, tabIds: [Int]) {
        self.id = id
        self.window = window
        self.name = name
        self.directory = directory
        self.tabCount = tabCount
        self.tabIds = tabIds
    }

    public static func formatHeader() -> [String] {
        [
            "ID",
            "Window",
            "Name",
            "Directory",
            "Tabs",
            "Tab IDs",
        ]
    }

    public func formatRow() -> [String] {
        [
            "\(self.id)",
            "\(self.window)",
            self.name,
            self.directory,
            "\(self.tabCount)",
            self.tabIds.map { "\($0)" }.joined(separator: ", "),
        ]
    }
}
