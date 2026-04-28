import Foundation

public struct WindowSnapshot: Codable, Sendable {
  public let id: Int
  public let sessions: [SessionSnapshot]
  public let activeSessionID: Int?

  public init(id: Int, sessions: [SessionSnapshot], activeSessionID: Int?) {
    self.id = id
    self.sessions = sessions
    self.activeSessionID = activeSessionID
  }
}
