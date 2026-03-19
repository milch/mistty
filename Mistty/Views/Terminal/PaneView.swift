import GhosttyKit
import SwiftUI

struct PaneView: View {
  let pane: MisttyPane
  let isActive: Bool
  var isWindowModeActive: Bool = false
  var isZoomed: Bool = false
  var copyModeState: CopyModeState?
  var windowModeState: MisttyTab.WindowModeState = .inactive
  var joinPickTabNames: [String] = []
  var paneCount: Int = 1
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
          RoundedRectangle(cornerRadius: 2)
            .stroke(Color.orange, lineWidth: 2)
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
            let reader: ((Int) -> String?)? = { row in
              guard let surface = pane.surfaceView.surface else { return nil }
              let size = ghostty_surface_size(surface)
              var sel = ghostty_selection_s()
              sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
              sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
              sel.top_left.x = 0
              sel.top_left.y = UInt32(row)
              sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
              sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
              sel.bottom_right.x = UInt32(size.columns - 1)
              sel.bottom_right.y = UInt32(row)
              sel.rectangle = false
              var text = ghostty_text_s()
              guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
              defer { ghostty_surface_free_text(surface, &text) }
              guard let ptr = text.text else { return nil }
              return String(cString: ptr)
            }
            CopyModeOverlay(
              state: state,
              cellWidth: cellW,
              cellHeight: cellH,
              gridOffsetX: offX,
              gridOffsetY: offY,
              lineReader: reader
            )
          }
        }
      }
      .onHover { hovering in
        isHovering = hovering
      }
  }
}
