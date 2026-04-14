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

      // Mode indicator
      VStack {
        Spacer()
        HStack {
          if state.subMode == .searchForward || state.subMode == .searchReverse {
            Text(searchBarText)
              .font(.system(size: 11, weight: .bold, design: .monospaced))
              .foregroundStyle(.white)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Color.blue.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
          } else {
            Text(modeIndicatorText)
              .font(.system(size: 11, weight: .bold, design: .monospaced))
              .foregroundStyle(.white)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Color.orange.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
          }
          Spacer()
        }
        .padding(4)
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

  private var modeIndicatorText: String {
    switch state.subMode {
    case .normal:
      if let idx = state.searchMatchIndex, let total = state.searchMatchTotal {
        return "-- COPY --  [\(idx)/\(total)]"
      }
      return "-- COPY --"
    case .visual: return "-- VISUAL --"
    case .visualLine: return "-- VISUAL LINE --"
    case .visualBlock: return "-- VISUAL BLOCK --"
    case .searchForward, .searchReverse: return ""
    case .hint: return "-- HINT --"
    }
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
