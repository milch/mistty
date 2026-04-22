import SwiftUI

struct CopyModeHintOverlay: View {
  let hint: HintState
  let viewportRows: Int
  let viewportCols: Int
  let cellWidth: CGFloat
  let cellHeight: CGFloat

  var body: some View {
    ZStack(alignment: .topLeading) {
      Rectangle()
        .fill(Color.black.opacity(0.4))
        .frame(
          width: cellWidth * CGFloat(viewportCols),
          height: cellHeight * CGFloat(viewportRows)
        )

      ForEach(Array(zip(hint.matches, hint.labels).enumerated()), id: \.offset) { idx, pair in
        let match = pair.0
        let label = pair.1
        pill(label: label, match: match)
      }
    }
    .allowsHitTesting(false)
  }

  private func pill(label: String, match: HintMatch) -> some View {
    let dimmed: Bool = {
      guard !hint.typedPrefix.isEmpty else { return false }
      return !label.hasPrefix(hint.typedPrefix)
    }()
    // Pattern hints sit to the LEFT of the match (no overlap). Line hints
    // sit at column 0 where the pill naturally falls in the indentation.
    let labelWidth = CGFloat(label.count) * cellWidth
    let baseX = CGFloat(match.range.startCol) * cellWidth
    let x: CGFloat = match.kind == .line ? baseX : max(0, baseX - labelWidth)
    let y = CGFloat(match.range.startRow) * cellHeight
    return Text(label)
      .font(.system(size: cellHeight * 0.7, weight: .bold, design: .monospaced))
      .foregroundStyle(dimmed ? Color.white.opacity(0.2) : Color.white)
      .padding(.horizontal, 2)
      .background(
        RoundedRectangle(cornerRadius: 2)
          .fill(dimmed ? Color.gray.opacity(0.3) : Color.purple)
      )
      .offset(x: x, y: y)
  }
}
