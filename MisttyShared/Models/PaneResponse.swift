import Foundation

public struct PaneResponse: Codable, Sendable {
    public let id: Int
    public let directory: String?

    public init(id: Int, directory: String?) {
        self.id = id
        self.directory = directory
    }
}
