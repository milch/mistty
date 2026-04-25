import SwiftUI

struct WindowModeHints: View {
  var isJoinPick: Bool = false
  var tabNames: [String] = []
  var paneCount: Int = 1

  private let normalHints: [(key: String, label: String)] = [
    ("←↑↓→", "swap"),
    ("hjkl", "focus"),
    ("⌘+arrows", "resize"),
    ("z", "zoom"),
    ("b", "break to tab"),
    ("m", "join to tab"),
    ("r", "rotate"),
    ("esc", "exit"),
  ]

  private let layoutHints: [(key: String, label: String)] = [
    ("1", "even-h"),
    ("2", "even-v"),
    ("3", "main-h"),
    ("4", "main-v"),
    ("5", "tiled"),
  ]

  var body: some View {
    VStack(spacing: 4) {
      hintsRow {
        if isJoinPick {
          Text("JOIN TO TAB")
            .fontWeight(.bold)
          if tabNames.isEmpty {
            Text("no other tabs")
          } else {
            ForEach(Array(tabNames.enumerated()), id: \.offset) { index, name in
              hintBadge(key: "\(index + 1)", label: name)
            }
          }
          hintBadge(key: "esc", label: "back")
        } else {
          Text("WINDOW")
            .fontWeight(.bold)
          ForEach(normalHints, id: \.key) { hint in
            hintBadge(key: hint.key, label: hint.label)
          }
        }
      }
      if !isJoinPick && paneCount >= 2 {
        hintsRow {
          Text("LAYOUT")
            .fontWeight(.bold)
          ForEach(layoutHints, id: \.key) { hint in
            hintBadge(key: hint.key, label: hint.label)
          }
        }
      }
    }
  }

  private func hintsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 12) {
      content()
    }
    .font(.system(size: 11, design: .monospaced))
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
  }

  private func hintBadge(key: String, label: String) -> some View {
    HStack(spacing: 3) {
      Text(key)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
      Text(label)
    }
  }
}
