import SwiftUI

struct TerminalSurfaceRepresentable: NSViewRepresentable {
  let pane: MisttyPane
  var onSelect: (() -> Void)?

  func makeNSView(context: Context) -> TerminalSurfaceView {
    let view = pane.surfaceView
    view.onSelect = onSelect
    return view
  }

  func updateNSView(_ nsView: TerminalSurfaceView, context: Context) {
    nsView.onSelect = onSelect
  }
}
