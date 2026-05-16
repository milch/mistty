import Foundation

@Observable
@MainActor
final class PopupState: Identifiable {
  let id: Int
  let definition: PopupDefinition
  let pane: MisttyPane
  var isVisible: Bool

  init(id: Int, definition: PopupDefinition, pane: MisttyPane, isVisible: Bool = true) {
    self.id = id
    self.definition = definition
    self.pane = pane
    self.isVisible = isVisible
  }
}
