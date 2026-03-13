import Foundation

public struct PopupResponse: Codable, Sendable {
    public let id: Int
    public let name: String
    public let command: String
    public let isVisible: Bool
    public let paneId: Int

    public init(id: Int, name: String, command: String, isVisible: Bool, paneId: Int) {
        self.id = id
        self.name = name
        self.command = command
        self.isVisible = isVisible
        self.paneId = paneId
    }
}
