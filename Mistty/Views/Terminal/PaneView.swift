import SwiftUI

struct PaneView: View {
    let pane: MisttyPane
    let isActive: Bool

    var body: some View {
        TerminalSurfaceRepresentable()
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}
