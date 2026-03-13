import Foundation

public struct TabResponse: Codable, Sendable {
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
}
