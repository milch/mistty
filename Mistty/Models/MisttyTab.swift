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

  enum WindowModeState {
    case inactive, normal, joinPick
  }

  var windowModeState: WindowModeState = .inactive
  var isWindowModeActive: Bool { windowModeState != .inactive }
  var copyModeState: CopyModeState?
  var isCopyModeActive: Bool { copyModeState != nil }
  var zoomedPane: MisttyPane?
  var layout: PaneLayout

  /// Closure that generates the next unique pane ID.
  @ObservationIgnored
  private(set) var paneIDGenerator: () -> Int

  init(id: Int, directory: URL? = nil, exec: String? = nil, paneIDGenerator: @escaping () -> Int) {
    self.id = id
    self.directory = directory
    self.paneIDGenerator = paneIDGenerator
    let pane = MisttyPane(id: paneIDGenerator())
    pane.directory = directory
    pane.command = exec
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
    // Inherit the focused pane's live CWD if the shell has reported one
    // (OSC 7); fall back to its initial directory, then the tab default.
    newPane.directory = activePane.currentWorkingDirectory
      ?? activePane.directory
      ?? directory
    layout.split(pane: activePane, direction: direction, newPane: newPane)
    panes = layout.leaves
    self.activePane = newPane
  }

  func addExistingPane(_ pane: MisttyPane, direction: SplitDirection) {
    guard let activePane else { return }
    layout.split(pane: activePane, direction: direction, newPane: pane)
    panes = layout.leaves
    self.activePane = pane
  }

  func closePane(_ pane: MisttyPane) {
    let wasActive = activePane?.id == pane.id
    layout.remove(pane: pane)
    panes = layout.leaves
    if wasActive {
      activePane = panes.last
      // The closed pane's OSC 2 title was what the tab last latched onto.
      // Replace with the new active pane's known title (or back to default).
      title = activePane?.processTitle ?? "Shell"
      // Without this, the focus ring moves to the new pane but first-responder
      // stays on the destroyed surface, so keystrokes go nowhere.
      activePane?.focusKeyboardInput()
    }
  }

  /// Make `pane` the active pane AND route keyboard input to it. Prefer this
  /// over writing `activePane` directly — the two must move together or the
  /// focus ring and first-responder desync.
  func focusPane(_ pane: MisttyPane) {
    activePane = pane
    pane.focusKeyboardInput()
  }

  func applyStandardLayout(_ standardLayout: StandardLayout) {
    let currentPanes = layout.leaves
    guard currentPanes.count >= 2 else { return }
    zoomedPane = nil
    layout = PaneLayout(root: LayoutEngine.apply(standardLayout, to: currentPanes))
    panes = layout.leaves
  }
}
