import Foundation

@Observable
@MainActor
final class MisttyTab: Identifiable {
  let id: Int
  var title: String = "Shell"
  var customTitle: String?

  var displayTitle: String {
    customTitle ?? title
  }
  let directory: URL?
  private(set) var panes: [MisttyPane] = []
  var activePane: MisttyPane?
  var hasBell = false
  var isWindowModeActive = false
  var copyModeState: CopyModeState?
  var isCopyModeActive: Bool { copyModeState != nil }
  var zoomedPane: MisttyPane?
  var layout: PaneLayout

  /// Closure that generates the next unique pane ID.
  @ObservationIgnored
  var paneIDGenerator: () -> Int

  init(id: Int, directory: URL? = nil, paneIDGenerator: @escaping () -> Int) {
    self.id = id
    self.directory = directory
    self.paneIDGenerator = paneIDGenerator
    let pane = MisttyPane(id: paneIDGenerator())
    pane.directory = directory
    layout = PaneLayout(pane: pane)
    panes = [pane]
    activePane = pane
  }

  init(id: Int, existingPane pane: MisttyPane, paneIDGenerator: @escaping () -> Int) {
    self.id = id
    self.directory = pane.directory
    self.paneIDGenerator = paneIDGenerator
    layout = PaneLayout(pane: pane)
    panes = [pane]
    activePane = pane
  }

  func splitActivePane(direction: SplitDirection) {
    guard let activePane else { return }
    let newPane = MisttyPane(id: paneIDGenerator())
    newPane.directory = directory
    layout.split(pane: activePane, direction: direction, newPane: newPane)
    panes = layout.leaves
    self.activePane = layout.leaves.last
  }

  func closePane(_ pane: MisttyPane) {
    layout.remove(pane: pane)
    panes = layout.leaves
    if activePane?.id == pane.id { activePane = panes.last }
  }
}
