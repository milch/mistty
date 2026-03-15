import SwiftUI

struct WindowModeHints: View {
  var isJoinPick: Bool = false
  var tabNames: [String] = []
  var paneCount: Int = 1

  private var normalHints: [(key: String, label: String)] {
    var hints: [(key: String, label: String)] = [
      ("←↑↓→", "swap"),
      ("⌘+arrows", "resize"),
      ("z", "zoom"),
      ("b", "break to tab"),
      ("m", "join to tab"),
      ("r", "rotate"),
    ]
    if paneCount >= 2 {
      hints.append(("1-5", "layout"))
    }
    hints.append(("esc", "exit"))
    return hints
  }

  var body: some View {
    HStack(spacing: 12) {
      if isJoinPick {
        Text("JOIN TO TAB")
          .fontWeight(.bold)
        if tabNames.isEmpty {
          Text("no other tabs")
        } else {
          ForEach(Array(tabNames.enumerated()), id: \.offset) { index, name in
            HStack(spacing: 3) {
              Text("\(index + 1)")
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
              Text(name)
            }
          }
        }
        HStack(spacing: 3) {
          Text("esc")
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
          Text("back")
        }
      } else {
        Text("WINDOW")
          .fontWeight(.bold)
        ForEach(normalHints, id: \.key) { hint in
          HStack(spacing: 3) {
            Text(hint.key)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            Text(hint.label)
          }
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
