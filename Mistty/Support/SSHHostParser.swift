import Foundation

/// Parses an SSH command string into the displayable host token.
///
/// Strategy: take the last token of the command that is NOT a flag
/// and is NOT the argument of a recognized ssh flag that takes a value
/// (`-p`, `-o`, `-i`, `-l`, `-F`, `-J`, `-b`, `-c`, `-D`, `-e`, `-E`,
/// `-I`, `-L`, `-m`, `-O`, `-Q`, `-R`, `-S`, `-w`). Split the token on
/// `@` and return the portion after it; if there's no `@`, return the
/// whole token.
enum SSHHostParser {
  private static let flagsTakingValue: Set<String> = [
    "-p", "-o", "-i", "-l", "-F", "-J", "-b", "-c", "-D",
    "-e", "-E", "-I", "-L", "-m", "-O", "-Q", "-R", "-S", "-w",
  ]

  static func host(from command: String) -> String? {
    let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard tokens.count >= 2 else { return nil }

    var i = 1  // skip the ssh binary itself
    var hostToken: String?
    while i < tokens.count {
      let tok = tokens[i]
      if flagsTakingValue.contains(tok) {
        i += 2  // skip flag and its value
        continue
      }
      if tok.hasPrefix("-") {
        i += 1
        continue
      }
      hostToken = tok
      i += 1
    }

    guard let raw = hostToken else { return nil }
    if let atIdx = raw.firstIndex(of: "@") {
      return String(raw[raw.index(after: atIdx)...])
    }
    return raw
  }
}
