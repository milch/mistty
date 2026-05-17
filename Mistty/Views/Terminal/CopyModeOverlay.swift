import SwiftUI

struct CopyModeOverlay: View {
  let state: CopyModeState
  let cellWidth: CGFloat
  let cellHeight: CGFloat
  var gridOffsetX: CGFloat = 0
  var gridOffsetY: CGFloat = 0
  var lineReader: ((Int) -> String?)? = nil

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Selection highlight
      if let range = state.selectionRange {
        SelectionHighlightView(
          start: range.start,
          end: range.end,
          cellWidth: cellWidth,
          cellHeight: cellHeight,
          mode: state.subMode,
          lineReader: lineReader,
          viewportRows: state.rows
        )
        .offset(x: gridOffsetX, y: gridOffsetY)
      }

      // Search highlights
      if !state.searchQuery.isEmpty, let reader = lineReader {
        SearchHighlightView(
          query: state.searchQuery,
          currentMatchRow: state.cursorRow,
          currentMatchCol: state.cursorCol,
          lineReader: reader,
          cellWidth: cellWidth,
          cellHeight: cellHeight,
          rows: state.rows
        )
        .offset(x: gridOffsetX, y: gridOffsetY)
      }

      // Cursor
      Rectangle()
        .fill(Color.yellow.opacity(0.7))
        .frame(width: cellWidth, height: cellHeight)
        .offset(
          x: gridOffsetX + CGFloat(state.cursorCol) * cellWidth,
          y: gridOffsetY + CGFloat(state.cursorRow) * cellHeight
        )

      // Hint overlay
      if state.isHinting, let hint = state.hint {
        CopyModeHintOverlay(
          hint: hint,
          viewportRows: state.rows,
          viewportCols: state.cols,
          cellWidth: cellWidth,
          cellHeight: cellHeight
        )
        .offset(x: gridOffsetX, y: gridOffsetY)
      }

      // Mode indicator — dodges the cursor by flipping to the top edge
      // when the cursor is in the bottom-left region (where the toast lives).
      // Hidden entirely when the user pressed `gh`.
      if !state.toastHidden {
        toastRow
          .frame(maxWidth: .infinity, maxHeight: .infinity,
                 alignment: dodgeToTop ? .topLeading : .bottomLeading)
          .animation(.easeInOut(duration: 0.18), value: dodgeToTop)
      }

      // Help overlay (g?)
      if state.showingHelp {
        CopyModeHelpOverlay()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black.opacity(0.3))
      }
    }
    .allowsHitTesting(false)
  }

  private var searchBarText: String {
    let prefix = state.subMode == .searchForward ? "/" : "?"
    let matchInfo: String
    if let idx = state.searchMatchIndex, let total = state.searchMatchTotal {
      matchInfo = "  [\(idx)/\(total)]"
    } else {
      matchInfo = ""
    }
    return "\(prefix)\(state.searchQuery)\u{2588}\(matchInfo)"
  }

  @ViewBuilder
  private var toastRow: some View {
    HStack {
      if state.subMode == .searchForward || state.subMode == .searchReverse {
        Text(searchBarText)
          .font(.system(size: 11, weight: .bold, design: .monospaced))
          .foregroundStyle(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Color.blue.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
      } else {
        CopyModeHints(state: state)
      }
      Spacer()
    }
    .padding(4)
  }

  /// Flip the toast to the top edge when the cursor is in the bottom-left
  /// region — the toast's default home. Bottom 25% of rows is enough room for
  /// the toast (single or two lines) plus a margin; the column check keeps
  /// the toast at the bottom when the cursor is on the right side of the
  /// viewport, since they don't overlap there.
  private var dodgeToTop: Bool {
    guard state.rows > 0, state.cols > 0 else { return false }
    let inBottomRows = state.cursorRow >= state.rows - max(2, state.rows / 4)
    let inLeftCols = state.cursorCol < (state.cols * 3) / 5
    return inBottomRows && inLeftCols
  }
}

struct SelectionHighlightView: View {
  let start: (row: Int, col: Int)
  let end: (row: Int, col: Int)
  let cellWidth: CGFloat
  let cellHeight: CGFloat
  let mode: CopySubMode
  let lineReader: ((Int) -> String?)?
  let viewportRows: Int

  var body: some View {
    Canvas { context, size in
      let minRow = min(start.row, end.row)
      let maxRow = max(start.row, end.row)
      // Clamp to visible viewport
      let visibleMin = max(minRow, 0)
      let visibleMax = min(maxRow, viewportRows - 1)
      guard visibleMin <= visibleMax else { return }

      switch mode {
      case .visual:
        drawCharacterWise(context: context, size: size, minRow: minRow, maxRow: maxRow, visibleMin: visibleMin, visibleMax: visibleMax)
      case .visualLine:
        drawLineWise(context: context, size: size, visibleMin: visibleMin, visibleMax: visibleMax)
      case .visualBlock:
        drawBlockWise(context: context, size: size, visibleMin: visibleMin, visibleMax: visibleMax)
      default:
        break
      }
    }
  }

  private func drawCharacterWise(context: GraphicsContext, size: CGSize, minRow: Int, maxRow: Int, visibleMin: Int, visibleMax: Int) {
    for row in visibleMin...visibleMax {
      let x0: CGFloat
      let x1: CGFloat
      if row == minRow && row == maxRow {
        // Entire selection on one row
        x0 = CGFloat(min(start.col, end.col)) * cellWidth
        x1 = CGFloat(max(start.col, end.col) + 1) * cellWidth
      } else if row == minRow {
        // First row of selection — from start col to end of line
        let startCol = start.row <= end.row ? start.col : end.col
        x0 = CGFloat(startCol) * cellWidth
        x1 = size.width
      } else if row == maxRow {
        // Last row of selection — from start of line to end col
        let endCol = start.row <= end.row ? end.col : start.col
        x0 = 0
        x1 = CGFloat(endCol + 1) * cellWidth
      } else {
        // Middle rows or rows where the actual start/end scrolled off-screen
        x0 = 0
        x1 = size.width
      }
      let rect = CGRect(x: x0, y: CGFloat(row) * cellHeight, width: x1 - x0, height: cellHeight)
      context.fill(Path(rect), with: .color(.blue.opacity(0.3)))
    }
  }

  private func drawLineWise(context: GraphicsContext, size: CGSize, visibleMin: Int, visibleMax: Int) {
    for row in visibleMin...visibleMax {
      let lineLen = lineReader?(row)?.count ?? 0
      let x1 = lineLen > 0 ? CGFloat(lineLen) * cellWidth : size.width
      let rect = CGRect(x: 0, y: CGFloat(row) * cellHeight, width: x1, height: cellHeight)
      context.fill(Path(rect), with: .color(.blue.opacity(0.3)))
    }
  }

  private func drawBlockWise(context: GraphicsContext, size: CGSize, visibleMin: Int, visibleMax: Int) {
    let minCol = min(start.col, end.col)
    let logicalRightCol = max(start.col, end.col)

    for row in visibleMin...visibleMax {
      let line = lineReader?(row) ?? ""
      let contentEnd = WordMotion.lastNonWhitespaceIndex(in: line)
      guard contentEnd >= minCol else { continue }
      let rightCol = min(logicalRightCol, contentEnd)
      let x0 = CGFloat(minCol) * cellWidth
      let x1 = CGFloat(rightCol + 1) * cellWidth
      let rect = CGRect(x: x0, y: CGFloat(row) * cellHeight, width: x1 - x0, height: cellHeight)
      context.fill(Path(rect), with: .color(.blue.opacity(0.3)))
    }
  }
}
