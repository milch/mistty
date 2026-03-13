import SwiftUI

struct PaneLayoutView: View {
    let node: PaneLayoutNode
    let activePane: MisttyPane?
    var onClosePane: ((MisttyPane) -> Void)?
    var onSelectPane: ((MisttyPane) -> Void)?

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneView(
                pane: pane,
                isActive: activePane?.id == pane.id,
                onClose: { onClosePane?(pane) },
                onSelect: { onSelectPane?(pane) }
            )
        case .split(.horizontal, let a, let b):
            HSplitView {
                PaneLayoutView(node: a, activePane: activePane, onClosePane: onClosePane, onSelectPane: onSelectPane)
                PaneLayoutView(node: b, activePane: activePane, onClosePane: onClosePane, onSelectPane: onSelectPane)
            }
        case .split(.vertical, let a, let b):
            VSplitView {
                PaneLayoutView(node: a, activePane: activePane, onClosePane: onClosePane, onSelectPane: onSelectPane)
                PaneLayoutView(node: b, activePane: activePane, onClosePane: onClosePane, onSelectPane: onSelectPane)
            }
        }
    }
}
