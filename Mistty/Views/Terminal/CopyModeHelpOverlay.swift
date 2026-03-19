import SwiftUI

struct CopyModeHelpOverlay: View {
    private let navHints: [(key: String, label: String)] = [
        ("h/j/k/l", "move cursor"),
        ("w/b/e", "word fwd/back/end"),
        ("W/B/E", "WORD motions"),
        ("ge/gE", "end of prev word/WORD"),
        ("0/$", "line start/end"),
        ("g/G", "top/bottom"),
        ("[count]", "repeat motion"),
    ]

    private let selectionHints: [(key: String, label: String)] = [
        ("v", "visual"),
        ("V", "visual line"),
        ("Ctrl-v", "visual block"),
        ("Esc", "exit visual"),
    ]

    private let findHints: [(key: String, label: String)] = [
        ("f/F", "find char"),
        ("t/T", "find before"),
        (";", "repeat find"),
        (",", "reverse find"),
    ]

    private let actionHints: [(key: String, label: String)] = [
        ("/", "search forward"),
        ("n", "next match"),
        ("y", "yank selection"),
        ("g?", "toggle this help"),
        ("Esc", "exit copy mode"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COPY MODE HELP")
                .font(.system(size: 12, weight: .bold, design: .monospaced))

            HStack(alignment: .top, spacing: 20) {
                hintColumn(title: "Navigation", hints: navHints)
                hintColumn(title: "Selection", hints: selectionHints)
                hintColumn(title: "Find on Line", hints: findHints)
                hintColumn(title: "Actions", hints: actionHints)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(12)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.6), lineWidth: 1)
        )
    }

    private func hintColumn(title: String, hints: [(key: String, label: String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .fontWeight(.bold)
                .padding(.bottom, 2)
            ForEach(hints, id: \.key) { hint in
                HStack(spacing: 6) {
                    Text(hint.key)
                        .frame(minWidth: 60, alignment: .trailing)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 2))
                    Text(hint.label)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }
}
