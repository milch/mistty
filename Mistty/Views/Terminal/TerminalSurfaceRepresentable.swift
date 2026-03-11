import SwiftUI

struct TerminalSurfaceRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalSurfaceView {
        TerminalSurfaceView(frame: .zero)
    }

    func updateNSView(_ nsView: TerminalSurfaceView, context: Context) {}
}
