import SwiftUI

struct PopupOverlayView: View {
  let popup: PopupState
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(popup.definition.name)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          onClose()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .font(.system(size: 14))
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.ultraThinMaterial)

      TerminalSurfaceRepresentable(pane: popup.pane, isActive: true)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.white.opacity(0.1), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.5), radius: 20, y: 5)
  }
}
