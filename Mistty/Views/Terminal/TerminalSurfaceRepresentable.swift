import SwiftUI

struct TerminalSurfaceRepresentable: NSViewRepresentable {
  let pane: MisttyPane
  var isActive: Bool = false
  var onSelect: (() -> Void)?

  func makeNSView(context: Context) -> TerminalSurfaceView {
    let view = pane.surfaceView
    view.onSelect = onSelect
    view.isActive = isActive
    return view
  }

  func updateNSView(_ nsView: TerminalSurfaceView, context: Context) {
    nsView.onSelect = onSelect
    nsView.isActive = isActive
  }
}
