import Foundation

public struct WindowResponse: Codable, Sendable {
    public let id: Int
    public let sessionCount: Int

    public init(id: Int, sessionCount: Int) {
        self.id = id
        self.sessionCount = sessionCount
    }
}
