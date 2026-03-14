import Foundation

@Observable
@MainActor
final class MisttySession: Identifiable {
  let id: Int
  var name: String
  let directory: URL
  private(set) var tabs: [MisttyTab] = []
  var activeTab: MisttyTab?

  private(set) var popups: [PopupState] = []
  var activePopup: PopupState?

  /// Closures that generate the next unique tab and pane IDs.
  @ObservationIgnored
  private(set) var tabIDGenerator: () -> Int
  @ObservationIgnored
  private(set) var paneIDGenerator: () -> Int
  @ObservationIgnored
  private(set) var popupIDGenerator: () -> Int

  init(id: Int, name: String, directory: URL, exec: String? = nil, tabIDGenerator: @escaping () -> Int, paneIDGenerator: @escaping () -> Int, popupIDGenerator: @escaping () -> Int) {
    self.id = id
    self.name = name
    self.directory = directory
    self.tabIDGenerator = tabIDGenerator
    self.paneIDGenerator = paneIDGenerator
    self.popupIDGenerator = popupIDGenerator
    addTab(exec: exec)
  }

  func addTab(exec: String? = nil) {
    let tab = MisttyTab(id: tabIDGenerator(), directory: directory, exec: exec, paneIDGenerator: paneIDGenerator)
    tabs.append(tab)
    activeTab = tab
  }

  func addTabWithPane(_ pane: MisttyPane) {
    let tab = MisttyTab(id: tabIDGenerator(), existingPane: pane, paneIDGenerator: paneIDGenerator)
    tabs.append(tab)
    activeTab = tab
  }

  func closeTab(_ tab: MisttyTab) {
    tabs.removeAll { $0.id == tab.id }
    if activeTab?.id == tab.id { activeTab = tabs.last }
  }

  func togglePopup(definition: PopupDefinition) {
    // If popup already exists for this definition, toggle visibility
    if let existing = popups.first(where: { $0.definition.name == definition.name }) {
      if existing.isVisible {
        existing.isVisible = false
        activePopup = nil
      } else {
        // Hide any other visible popup first
        activePopup?.isVisible = false
        existing.isVisible = true
        activePopup = existing
      }
      return
    }

    // Create new popup — use current pane's directory if available
    activePopup?.isVisible = false
    let pane = MisttyPane(id: paneIDGenerator())
    pane.directory = activeTab?.activePane?.directory ?? directory
    pane.command = definition.command
    if definition.closeOnExit {
      pane.useCommandField = false
    }
    let popup = PopupState(id: popupIDGenerator(), definition: definition, pane: pane)
    popups.append(popup)
    activePopup = popup
  }

  func openPopup(definition: PopupDefinition) {
    if let existing = popups.first(where: { $0.definition.name == definition.name }) {
      if !existing.isVisible {
        activePopup?.isVisible = false
        existing.isVisible = true
        activePopup = existing
      }
      return
    }
    // Create new popup — use current pane's directory if available
    activePopup?.isVisible = false
    let pane = MisttyPane(id: paneIDGenerator())
    pane.directory = activeTab?.activePane?.directory ?? directory
    pane.command = definition.command
    if definition.closeOnExit {
      pane.useCommandField = false
    }
    let popup = PopupState(id: popupIDGenerator(), definition: definition, pane: pane)
    popups.append(popup)
    activePopup = popup
  }

  func closePopup(_ popup: PopupState) {
    popups.removeAll { $0.id == popup.id }
    if activePopup?.id == popup.id { activePopup = nil }
  }

  func hideActivePopup() {
    activePopup?.isVisible = false
    activePopup = nil
  }

  func nextTab() {
    guard let current = activeTab,
          let index = tabs.firstIndex(where: { $0.id == current.id })
    else { return }
    activeTab = tabs[(index + 1) % tabs.count]
  }

  func prevTab() {
    guard let current = activeTab,
          let index = tabs.firstIndex(where: { $0.id == current.id })
    else { return }
    activeTab = tabs[(index - 1 + tabs.count) % tabs.count]
  }
}
