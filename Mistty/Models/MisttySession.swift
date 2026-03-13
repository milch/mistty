import Foundation

@Observable
@MainActor
final class MisttySession: Identifiable {
  let id: Int
  var name: String
  let directory: URL
  private(set) var tabs: [MisttyTab] = []
  var activeTab: MisttyTab?

  /// Closures that generate the next unique tab and pane IDs.
  @ObservationIgnored
  private(set) var tabIDGenerator: () -> Int
  @ObservationIgnored
  private(set) var paneIDGenerator: () -> Int

  init(id: Int, name: String, directory: URL, exec: String? = nil, tabIDGenerator: @escaping () -> Int, paneIDGenerator: @escaping () -> Int) {
    self.id = id
    self.name = name
    self.directory = directory
    self.tabIDGenerator = tabIDGenerator
    self.paneIDGenerator = paneIDGenerator
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
}
