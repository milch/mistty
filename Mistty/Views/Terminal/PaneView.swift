import SwiftUI

struct PaneView: View {
    let pane: MisttyPane
    let isActive: Bool
    var onClose: (() -> Void)?
    var onSelect: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        TerminalSurfaceRepresentable(pane: pane, onSelect: onSelect)
            .id(pane.id)
            .overlay(alignment: .topTrailing) {
                if isHovering, let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
