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
  /// Source of truth for the panes owned by this tab. `layout` references
  /// these via ID. When this array drops a pane, the pane (and its
  /// libghostty surface) is deallocated — independent of whether the
  /// layout enum's stale heap allocation is still cached in some SwiftUI
  /// view tree.
  private(set) var panes: [MisttyPane] = []
  var activePane: MisttyPane?
  var hasBell = false

  enum WindowModeState {
    case inactive, normal, joinPick
  }

  var windowModeState: WindowModeState = .inactive
  var isWindowModeActive: Bool { windowModeState != .inactive }

  /// Convenience: is the *focused* pane in copy mode? Each pane keeps its
  /// own `copyModeState`; this just asks the active one.
  var isCopyModeActive: Bool { activePane?.isCopyModeActive ?? false }
  var copyModeState: CopyModeState? {
    get { activePane?.copyModeState }
    set { activePane?.copyModeState = newValue }
  }
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

  /// Reorder `panes` to match `layout`'s left-to-right / top-to-bottom
  /// traversal. Called after layout mutations and after `restore` wires
  /// a new tree in.
  func refreshPanesFromLayout() {
    let order = layout.leafIDs
    let byID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
    panes = order.compactMap { byID[$0] }
  }

  /// Install a complete set of panes (e.g. during state restoration) and
  /// reorder them to match the layout's traversal order.
  func installPanes(_ newPanes: [MisttyPane]) {
    panes = newPanes
    refreshPanesFromLayout()
  }

  /// Look up a pane owned by this tab by its ID.
  func pane(byID id: Int) -> MisttyPane? {
    panes.first { $0.id == id }
  }

  func splitActivePane(direction: SplitDirection) {
    guard let activePane else { return }
    let newPane = MisttyPane(id: paneIDGenerator())
    // Inherit the focused pane's live CWD if the shell has reported one
    // (OSC 7); fall back to its initial directory, then the tab default.
    newPane.directory = activePane.currentWorkingDirectory
      ?? activePane.directory
      ?? directory
    panes.append(newPane)
    layout.split(pane: activePane, direction: direction, newPane: newPane)
    refreshPanesFromLayout()
    self.activePane = newPane
  }

  func addExistingPane(_ pane: MisttyPane, direction: SplitDirection) {
    guard let activePane else { return }
    panes.append(pane)
    layout.split(pane: activePane, direction: direction, newPane: pane)
    refreshPanesFromLayout()
    self.activePane = pane
  }

  func closePane(_ pane: MisttyPane) {
    let wasActive = activePane?.id == pane.id
    let closingID = pane.id
    layout.remove(pane: pane)
    panes.removeAll { $0.id == pane.id }
    if wasActive {
      activePane = panes.last
      // The closed pane's OSC 2 title was what the tab last latched onto.
      // Replace with the new active pane's known title (or back to default).
      title = activePane?.processTitle ?? "Shell"
      // Without this, the focus ring moves to the new pane but first-responder
      // stays on the destroyed surface, so keystrokes go nowhere.
      activePane?.focusKeyboardInput()
    }
    if zoomedPane?.id == closingID { zoomedPane = nil }
    // Force-release the libghostty surface + threads + IOSurfaces NOW.
    // SwiftUI's view-tree cache + AppKit's `_commonAwake` notification
    // observer keep the `MisttyPane` + `TerminalSurfaceView` instances
    // alive past `closePane`. Without this call the heavy resources
    // accumulate — see the 9GB / 17-day scenario investigated in
    // `b406c48`. The Swift objects may still leak (small per-object
    // cost) but the multi-MB-per-pane GPU + thread resources are
    // reliably released.
    pane.releaseResources()
  }

  /// Make `pane` the active pane AND route keyboard input to it. Prefer this
  /// over writing `activePane` directly — the two must move together or the
  /// focus ring and first-responder desync.
  func focusPane(_ pane: MisttyPane) {
    activePane = pane
    pane.focusKeyboardInput()
  }

  func applyStandardLayout(_ standardLayout: StandardLayout) {
    guard panes.count >= 2 else { return }
    zoomedPane = nil
    layout = PaneLayout(root: LayoutEngine.apply(standardLayout, to: panes))
    refreshPanesFromLayout()
  }
}
