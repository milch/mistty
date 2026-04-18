import SwiftUI

struct PaneLayoutView: View {
  let node: PaneLayoutNode
  let activePane: MisttyPane?
  var isWindowModeActive: Bool = false
  var copyModeState: CopyModeState?
  var copyModePaneID: Int?
  var windowModeState: MisttyTab.WindowModeState = .inactive
  var joinPickTabNames: [String] = []
  var paneCount: Int = 1
  var borderColor: Color = Color(NSColor.separatorColor)
  var borderWidth: CGFloat = 1
  var onClosePane: ((MisttyPane) -> Void)?
  var onSelectPane: ((MisttyPane) -> Void)?

  var body: some View {
    switch node {
    case .empty:
      Color(nsColor: .windowBackgroundColor)
    case .leaf(let pane):
      PaneView(
        pane: pane,
        isActive: activePane?.id == pane.id,
        isWindowModeActive: isWindowModeActive,
        copyModeState: (pane.id == copyModePaneID) ? copyModeState : nil,
        windowModeState: windowModeState,
        joinPickTabNames: joinPickTabNames,
        paneCount: paneCount,
        onClose: { onClosePane?(pane) },
        onSelect: { onSelectPane?(pane) }
      )
    case .split(let direction, let a, let b, let ratio):
      GeometryReader { geo in
        if direction == .horizontal {
          HStack(spacing: 0) {
            child(a)
              .frame(width: geo.size.width * ratio)
            borderColor
              .frame(width: borderWidth)
            child(b)
          }
        } else {
          VStack(spacing: 0) {
            child(a)
              .frame(height: geo.size.height * ratio)
            borderColor
              .frame(height: borderWidth)
            child(b)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func child(_ node: PaneLayoutNode) -> some View {
    PaneLayoutView(
      node: node, activePane: activePane, isWindowModeActive: isWindowModeActive,
      copyModeState: copyModeState, copyModePaneID: copyModePaneID,
      windowModeState: windowModeState, joinPickTabNames: joinPickTabNames,
      paneCount: paneCount,
      borderColor: borderColor, borderWidth: borderWidth,
      onClosePane: onClosePane, onSelectPane: onSelectPane
    )
  }
}
