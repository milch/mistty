import SwiftUI

struct PaneLayoutView: View {
    let node: PaneLayoutNode
    let activePane: MisttyPane?

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneView(pane: pane, isActive: activePane?.id == pane.id)
        case .split(.horizontal, let a, let b):
            HSplitView {
                PaneLayoutView(node: a, activePane: activePane)
                PaneLayoutView(node: b, activePane: activePane)
            }
        case .split(.vertical, let a, let b):
            VSplitView {
                PaneLayoutView(node: a, activePane: activePane)
                PaneLayoutView(node: b, activePane: activePane)
            }
        }
    }
}
