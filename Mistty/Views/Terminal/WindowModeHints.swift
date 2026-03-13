import SwiftUI

struct WindowModeHints: View {
  private let hints: [(key: String, label: String)] = [
    ("←↑↓→", "swap"),
    ("⌘+arrows", "resize"),
    ("z", "zoom"),
    ("b", "break to tab"),
    ("r", "rotate"),
    ("esc", "exit"),
  ]

  var body: some View {
    HStack(spacing: 12) {
      Text("WINDOW")
        .fontWeight(.bold)
      ForEach(hints, id: \.key) { hint in
        HStack(spacing: 3) {
          Text(hint.key)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
          Text(hint.label)
        }
      }
    }
    .font(.system(size: 11, design: .monospaced))
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
  }
}
