import SwiftUI

struct PaneView: View {
  let pane: MisttyPane
  let isActive: Bool
  var isWindowModeActive: Bool = false
  var isZoomed: Bool = false
  var copyModeState: CopyModeState?
  var windowModeState: MisttyTab.WindowModeState = .inactive
  var joinPickTabNames: [String] = []
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
        if isActive && windowModeState != .inactive {
          ZStack {
            RoundedRectangle(cornerRadius: 2)
              .stroke(Color.orange, lineWidth: 2)
            VStack {
              Spacer()
              WindowModeHints(
                isJoinPick: windowModeState == .joinPick,
                tabNames: joinPickTabNames
              )
                .padding(6)
            }
          }
          .allowsHitTesting(false)
        } else if isActive {
          RoundedRectangle(cornerRadius: 2)
            .stroke(Color.accentColor, lineWidth: 1)
            .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .topLeading) {
        if isZoomed {
          Text("⊕ ZOOMED")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
            .allowsHitTesting(false)
        }
      }
      .overlay {
        if let state = copyModeState {
          GeometryReader { geo in
            let metrics = pane.surfaceView.gridMetrics()
            let cellW = metrics?.cellWidth ?? geo.size.width / CGFloat(state.cols)
            let cellH = metrics?.cellHeight ?? geo.size.height / CGFloat(state.rows)
            let offX = metrics?.offsetX ?? 0
            let offY = metrics?.offsetY ?? 0
            CopyModeOverlay(
              state: state,
              cellWidth: cellW,
              cellHeight: cellH,
              gridOffsetX: offX,
              gridOffsetY: offY
            )
          }
        }
      }
      .onHover { hovering in
        isHovering = hovering
      }
  }
}
