import Foundation

public struct TabResponse: Codable, Sendable, PrintableByFormatter {
    public let id: Int
    public let title: String
    public let paneCount: Int
    public let paneIds: [Int]

    public init(id: Int, title: String, paneCount: Int, paneIds: [Int]) {
        self.id = id
        self.title = title
        self.paneCount = paneCount
        self.paneIds = paneIds
    }

    public static func formatHeader() -> [String] {

        [
            "ID",
            "Title",
            "Panes",
            "Pane IDs",
        ]
    }

    public func formatRow() -> [String] {
        [
            "\(self.id)",
            self.title,
            "\(self.paneCount)",
            self.paneIds.map { "\($0)" }.joined(separator: ", "),
        ]
    }

}
