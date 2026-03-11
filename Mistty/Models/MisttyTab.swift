import Foundation

@Observable
final class MisttyTab: Identifiable {
    let id = UUID()
    var title: String = "Shell"
    private(set) var panes: [MisttyPane] = []
    var activePane: MisttyPane?
    var layout: PaneLayout

    init() {
        let pane = MisttyPane()
        layout = PaneLayout(pane: pane)
        panes = [pane]
        activePane = pane
    }

    func splitActivePane(direction: SplitDirection) {
        guard let activePane else { return }
        layout.split(pane: activePane, direction: direction)
        panes = layout.leaves
        self.activePane = layout.leaves.last
    }

    func closePane(_ pane: MisttyPane) {
        panes.removeAll { $0.id == pane.id }
        if activePane?.id == pane.id { activePane = panes.last }
    }
}
