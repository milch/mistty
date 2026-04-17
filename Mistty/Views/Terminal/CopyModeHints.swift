import SwiftUI

struct CopyModeHints: View {
  let state: CopyModeState

  var body: some View {
    VStack(spacing: 4) {
      hintsRow {
        Text(title).fontWeight(.bold)
        ForEach(hints, id: \.key) { hint in
          hintBadge(key: hint.key, label: hint.label)
        }
      }
    }
  }

  private var title: String {
    switch state.subMode {
    case .normal: return "COPY"
    case .visual: return "VISUAL"
    case .visualLine: return "VISUAL LINE"
    case .visualBlock: return "VISUAL BLOCK"
    case .hint:
      if state.hint?.source == .lines { return "HINT (line)" }
      let mode = state.hint?.action == .open ? "open" : "copy"
      let filter = filterLabel(state.hint?.filter)
      return "HINT (\(mode) · \(filter))"
    case .searchForward, .searchReverse: return "SEARCH"
    }
  }

  private var hints: [(key: String, label: String)] {
    switch state.subMode {
    case .normal:
      return [
        ("v/V", "visual"),
        ("/", "search"),
        ("y/o", "hints"),
        ("Y", "line hints"),
        ("g?", "help"),
        ("esc", "exit"),
      ]
    case .visual, .visualLine, .visualBlock:
      return [
        ("y", "yank"),
        ("esc", "cancel"),
      ]
    case .hint:
      var rows: [(key: String, label: String)] = [
        ("a-z", "pick hint"),
        ("A-Z", "swap copy/open"),
      ]
      if state.hint?.source == .patterns {
        rows.append(("tab", "filter kind"))
      }
      rows.append(("esc", "exit"))
      return rows
    case .searchForward, .searchReverse:
      return [("↵", "confirm"), ("esc", "cancel")]
    }
  }

  private func filterLabel(_ kind: HintKind?) -> String {
    guard let k = kind else { return "all" }
    switch k {
    case .url: return "url"
    case .email: return "email"
    case .uuid: return "uuid"
    case .path: return "path"
    case .hash: return "hash"
    case .ipv4: return "ipv4"
    case .ipv6: return "ipv6"
    case .envVar: return "env"
    case .number: return "num"
    case .quoted: return "quote"
    case .codeSpan: return "code"
    case .line: return "line"
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
