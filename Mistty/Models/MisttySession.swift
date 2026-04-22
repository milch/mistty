import Foundation

@Observable
@MainActor
final class MisttySession: Identifiable {
  let id: Int
  var name: String
  var customName: String?
  let directory: URL
  var sshCommand: String?
  /// Set by `SessionStore.activeSession.didSet`; only read at sort time in the
  /// session manager. No SwiftUI view observes it, so opt out of
  /// `@Observable` invalidation to avoid spurious re-renders on every
  /// activation flip.
  @ObservationIgnored
  var lastActivatedAt: Date = Date()
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

  init(
    id: Int, name: String, directory: URL, exec: String? = nil,
    customName: String? = nil,
    tabIDGenerator: @escaping () -> Int,
    paneIDGenerator: @escaping () -> Int, popupIDGenerator: @escaping () -> Int
  ) {
    self.id = id
    self.name = name
    self.customName = customName
    self.directory = directory
    self.tabIDGenerator = tabIDGenerator
    self.paneIDGenerator = paneIDGenerator
    self.popupIDGenerator = popupIDGenerator
    addTab(exec: exec)
  }

  func addTab(exec: String? = nil) {
    let tab = MisttyTab(
      id: tabIDGenerator(), directory: directory, exec: exec, paneIDGenerator: paneIDGenerator)
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

    activePopup?.isVisible = false
    let pane = MisttyPane(id: paneIDGenerator())
    pane.directory = popupDirectory(for: definition.cwdSource)
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
    activePopup?.isVisible = false
    let pane = MisttyPane(id: paneIDGenerator())
    pane.directory = popupDirectory(for: definition.cwdSource)
    pane.command = definition.command
    if definition.closeOnExit {
      pane.useCommandField = false
    }
    let popup = PopupState(id: popupIDGenerator(), definition: definition, pane: pane)
    popups.append(popup)
    activePopup = popup
  }

  /// Resolve the starting directory for a new popup pane. Falls through from
  /// live CWD → initial pane directory → session directory → home so a newly
  /// spawned pane (no OSC 7 yet) still gets a sensible value.
  private func popupDirectory(for source: PopupCwdSource) -> URL {
    switch source {
    case .session:
      return directory
    case .home:
      return FileManager.default.homeDirectoryForCurrentUser
    case .activePane:
      if let pane = activeTab?.activePane {
        return pane.currentWorkingDirectory ?? pane.directory ?? directory
      }
      return directory
    }
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

  var sidebarLabel: String {
    if let customName, !customName.isEmpty {
      return customName
    }
    if let sshCommand, let host = SSHHostParser.host(from: sshCommand), !host.isEmpty {
      return host
    }
    if let cwd = activeTab?.activePane?.directory {
      return cwd.lastPathComponent
    }
    return directory.lastPathComponent
  }
}
