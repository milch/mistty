import SwiftUI

struct PaneLayoutView: View {
    let node: PaneLayoutNode
    let activePane: MisttyPane?
    var isWindowModeActive: Bool = false
    var onClosePane: ((MisttyPane) -> Void)?
    var onSelectPane: ((MisttyPane) -> Void)?

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneView(
                pane: pane,
                isActive: activePane?.id == pane.id,
                isWindowModeActive: isWindowModeActive,
                onClose: { onClosePane?(pane) },
                onSelect: { onSelectPane?(pane) }
            )
        case .split(let direction, let a, let b, let ratio):
            GeometryReader { geo in
                if direction == .horizontal {
                    HStack(spacing: 1) {
                        PaneLayoutView(node: a, activePane: activePane, isWindowModeActive: isWindowModeActive,
                                      onClosePane: onClosePane, onSelectPane: onSelectPane)
                            .frame(width: geo.size.width * ratio)
                        Divider()
                        PaneLayoutView(node: b, activePane: activePane, isWindowModeActive: isWindowModeActive,
                                      onClosePane: onClosePane, onSelectPane: onSelectPane)
                    }
                } else {
                    VStack(spacing: 1) {
                        PaneLayoutView(node: a, activePane: activePane, isWindowModeActive: isWindowModeActive,
                                      onClosePane: onClosePane, onSelectPane: onSelectPane)
                            .frame(height: geo.size.height * ratio)
                        Divider()
                        PaneLayoutView(node: b, activePane: activePane, isWindowModeActive: isWindowModeActive,
                                      onClosePane: onClosePane, onSelectPane: onSelectPane)
                    }
                }
            }
        }
    }
}
