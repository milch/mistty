import Foundation

/// Maps process titles to Nerd Font glyphs for sidebar display.
///
/// Glyph codepoints source: Nerd Fonts v3 cheat sheet.
/// https://www.nerdfonts.com/cheat-sheet
enum ProcessIcon {
  static let fontName = "SymbolsNerdFontMono"

  static let fallbackGlyph: Character = "\u{f489}"  // nf-dev-terminal
  static let sshGlyph: Character = "\u{f0c2e}"  // nf-md-ssh
  static let nvimGlyph: Character = "\u{e7c5}"  // nf-dev-vim

  private static let map: [String: Character] = [
    "nvim": nvimGlyph, "vim": nvimGlyph, "neovim": nvimGlyph,
    "claude": "\u{f0335}",
    "zsh": "\u{f489}", "bash": "\u{f489}", "fish": "\u{f489}", "sh": "\u{f489}",
    "node": "\u{e718}", "npm": "\u{e71e}", "pnpm": "\u{e718}", "yarn": "\u{e6a7}",
    "python": "\u{e73c}", "python3": "\u{e73c}", "ipython": "\u{e73c}",
    "ruby": "\u{e739}", "irb": "\u{e739}",
    "go": "\u{e627}",
    "cargo": "\u{e7a8}", "rustc": "\u{e7a8}",
    "docker": "\u{f308}",
    "git": "\u{f1d3}", "lazygit": "\u{f1d3}",
    "ssh": sshGlyph, "mosh": sshGlyph,
    "tmux": "\u{ebc8}",
    "htop": "\u{f2db}", "btop": "\u{f2db}",
    "mysql": "\u{e704}", "psql": "\u{e76e}",
    "make": "\u{e673}",
  ]

  static func glyph(forProcessTitle title: String?) -> Character {
    guard let normalized = normalize(title) else { return fallbackGlyph }
    return map[normalized] ?? fallbackGlyph
  }

  private static func normalize(_ title: String?) -> String? {
    guard let title = title?.lowercased() else { return nil }
    let firstToken = title.split(separator: " ").first.map(String.init) ?? title
    return firstToken.isEmpty ? nil : firstToken
  }
}
