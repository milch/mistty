import Foundation

@Observable
@MainActor
final class MisttyTab: Identifiable {
    let id = UUID()
    var title: String = "Shell"
    let directory: URL?
    private(set) var panes: [MisttyPane] = []
    var activePane: MisttyPane?
    var hasBell = false
    var layout: PaneLayout

    init(directory: URL? = nil) {
        self.directory = directory
        let pane = MisttyPane()
        pane.directory = directory
        layout = PaneLayout(pane: pane)
        panes = [pane]
        activePane = pane
    }

    func splitActivePane(direction: SplitDirection) {
        guard let activePane else { return }
        layout.split(pane: activePane, direction: direction, directory: directory)
        panes = layout.leaves
        self.activePane = layout.leaves.last
    }

    func closePane(_ pane: MisttyPane) {
        layout.remove(pane: pane)
        panes = layout.leaves
        if activePane?.id == pane.id { activePane = panes.last }
    }
}
