import SwiftUI

struct SearchHighlightView: View {
  let query: String
  let currentMatchRow: Int?
  let currentMatchCol: Int?
  let lineReader: (Int) -> String?
  let cellWidth: CGFloat
  let cellHeight: CGFloat
  let rows: Int

  var body: some View {
    Canvas { context, size in
      guard !query.isEmpty else { return }

      for row in 0..<rows {
        guard let line = lineReader(row) else { continue }

        var searchStart = line.startIndex
        while let range = line.range(of: query, options: .caseInsensitive, range: searchStart..<line.endIndex) {
          let col = line.distance(from: line.startIndex, to: range.lowerBound)
          let matchLen = line.distance(from: range.lowerBound, to: range.upperBound)

          let isCurrent = row == currentMatchRow && col == currentMatchCol
          let color: Color = isCurrent
            ? .orange.opacity(0.6)
            : .yellow.opacity(0.3)

          let rect = CGRect(
            x: CGFloat(col) * cellWidth,
            y: CGFloat(row) * cellHeight,
            width: CGFloat(matchLen) * cellWidth,
            height: cellHeight
          )
          context.fill(Path(rect), with: .color(color))

          searchStart = range.upperBound
        }
      }
    }
  }
}
