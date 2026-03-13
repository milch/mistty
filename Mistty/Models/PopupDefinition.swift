import Foundation

struct PopupDefinition: Codable, Sendable, Equatable {
  var name: String
  var command: String
  var shortcut: String?
  var width: Double
  var height: Double
  var closeOnExit: Bool

  init(
    name: String,
    command: String,
    shortcut: String? = nil,
    width: Double = 0.8,
    height: Double = 0.8,
    closeOnExit: Bool = true
  ) {
    self.name = name
    self.command = command
    self.shortcut = shortcut
    self.width = width
    self.height = height
    self.closeOnExit = closeOnExit
  }
}
