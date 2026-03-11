import Foundation

@Observable
final class MisttyTab: Identifiable {
    let id = UUID()
    var title: String = "Shell"
    private(set) var panes: [MisttyPane] = []
    var activePane: MisttyPane?

    init() {
        let pane = MisttyPane()
        panes = [pane]
        activePane = pane
    }

    func splitActivePane(direction: SplitDirection) {
        let newPane = MisttyPane()
        panes.append(newPane)
        activePane = newPane
    }

    func closePane(_ pane: MisttyPane) {
        panes.removeAll { $0.id == pane.id }
        if activePane?.id == pane.id { activePane = panes.last }
    }
}
