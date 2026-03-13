import SwiftUI

struct CopyModeOverlay: View {
  let state: CopyModeState
  let cellWidth: CGFloat
  let cellHeight: CGFloat

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Selection highlight
      if let range = state.selectionRange {
        SelectionHighlightView(
          start: range.start,
          end: range.end,
          cellWidth: cellWidth,
          cellHeight: cellHeight
        )
      }

      // Cursor
      Rectangle()
        .fill(Color.yellow.opacity(0.7))
        .frame(width: cellWidth, height: cellHeight)
        .offset(
          x: CGFloat(state.cursorCol) * cellWidth,
          y: CGFloat(state.cursorRow) * cellHeight
        )

      // Mode indicator
      VStack {
        Spacer()
        HStack {
          Text(state.isSelecting ? "-- VISUAL --" : "-- COPY --")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
          Spacer()
        }
        .padding(4)
      }
    }
    .allowsHitTesting(false)
  }
}

struct SelectionHighlightView: View {
  let start: (row: Int, col: Int)
  let end: (row: Int, col: Int)
  let cellWidth: CGFloat
  let cellHeight: CGFloat

  var body: some View {
    Canvas { context, size in
      let minRow = min(start.row, end.row)
      let maxRow = max(start.row, end.row)

      for row in minRow...maxRow {
        let x0: CGFloat
        let x1: CGFloat
        if row == minRow && row == maxRow {
          x0 = CGFloat(min(start.col, end.col)) * cellWidth
          x1 = CGFloat(max(start.col, end.col) + 1) * cellWidth
        } else if row == minRow {
          let startCol = start.row <= end.row ? start.col : end.col
          x0 = CGFloat(startCol) * cellWidth
          x1 = size.width
        } else if row == maxRow {
          let endCol = start.row <= end.row ? end.col : start.col
          x0 = 0
          x1 = CGFloat(endCol + 1) * cellWidth
        } else {
          x0 = 0
          x1 = size.width
        }
        let rect = CGRect(x: x0, y: CGFloat(row) * cellHeight, width: x1 - x0, height: cellHeight)
        context.fill(Path(rect), with: .color(.blue.opacity(0.3)))
      }
    }
  }
}
