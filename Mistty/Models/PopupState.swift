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
    DebugLog.shared.log(
      "popup", "PopupState init id=\(id) name='\(definition.name)' paneID=\(pane.id)")
  }

  deinit {
    let capturedID = id
    let capturedName = definition.name
    let capturedPaneID = pane.id
    Task { @MainActor in
      DebugLog.shared.log(
        "popup",
        "PopupState deinit id=\(capturedID) name='\(capturedName)' paneID=\(capturedPaneID)")
    }
  }
}
