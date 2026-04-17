import XCTest
@testable import Mistty

final class CopyModeHintIntegrationTests: XCTestCase {

  private func makeState(lines: [String]) -> (CopyModeState, (Int) -> String?) {
    let rows = lines.count
    let cols = lines.map(\.count).max() ?? 80
    let state = CopyModeState(rows: rows, cols: cols, cursorRow: 0, cursorCol: 0)
    let reader: (Int) -> String? = { r in r < lines.count ? lines[r] : nil }
    return (state, reader)
  }

  private func simulate(
    _ state: inout CopyModeState,
    reader: (Int) -> String?,
    keys: String
  ) -> [CopyModeAction] {
    var collected: [CopyModeAction] = []
    for ch in keys {
      let actions = state.handleKey(key: ch, keyCode: 0, modifiers: [], lineReader: reader)
      collected.append(contentsOf: actions)
    }
    return collected
  }

  func test_y_enters_hint_mode_copy() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    let actions = simulate(&state, reader: reader, keys: "y")
    XCTAssertTrue(actions.contains(.enterHintMode(.copy, .patterns)))
    XCTAssertTrue(actions.contains(.requestHintScan))
  }

  func test_o_enters_hint_mode_open() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    let actions = simulate(&state, reader: reader, keys: "o")
    XCTAssertTrue(actions.contains(.enterHintMode(.open, .patterns)))
  }

  func test_Y_enters_hint_mode_lines() {
    var (state, reader) = makeState(lines: ["hello"])
    let actions = simulate(&state, reader: reader, keys: "Y")
    XCTAssertTrue(actions.contains(.enterHintMode(.copy, .lines)))
  }

  func test_single_char_label_copies_and_exits() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    _ = simulate(&state, reader: reader, keys: "y")
    state.applyHintEntry(action: .copy, source: .patterns)
    state.setHintMatches(
      HintDetector.detect(lines: ["see https://example.com"], source: .patterns)
    )
    let actions = simulate(&state, reader: reader, keys: "a")
    XCTAssertTrue(actions.contains(.copyText("https://example.com")))
    XCTAssertTrue(actions.contains(.exitHintMode))
    XCTAssertTrue(actions.contains(.exitCopyMode))
  }

  func test_uppercase_swaps_action_to_open() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    _ = simulate(&state, reader: reader, keys: "y")
    state.applyHintEntry(action: .copy, source: .patterns)
    state.setHintMatches(
      HintDetector.detect(lines: ["see https://example.com"], source: .patterns)
    )
    let actions = simulate(&state, reader: reader, keys: "A")
    XCTAssertTrue(actions.contains(.openItem("https://example.com")))
  }

  func test_mismatch_exits_hint_mode_but_not_copy_mode() {
    var (state, reader) = makeState(lines: ["see https://example.com"])
    _ = simulate(&state, reader: reader, keys: "y")
    state.applyHintEntry(action: .copy, source: .patterns)
    state.setHintMatches(
      HintDetector.detect(lines: ["see https://example.com"], source: .patterns)
    )
    let actions = simulate(&state, reader: reader, keys: "z")
    XCTAssertTrue(actions.contains(.exitHintMode))
    XCTAssertFalse(actions.contains(where: {
      if case .exitCopyMode = $0 { return true } else { return false }
    }))
    XCTAssertEqual(state.subMode, .normal)
  }

  func test_two_char_label_routing() {
    // Force >9 matches so 2-char labels appear.
    var lines: [String] = []
    for i in 0..<12 {
      lines.append("url http://ex\(i).com")
    }
    var (state, reader) = makeState(lines: lines)
    _ = simulate(&state, reader: reader, keys: "y")
    let matches = HintDetector.detect(lines: lines, source: .patterns)
    state.applyHintEntry(action: .copy, source: .patterns, alphabet: "asdf")
    state.setHintMatches(matches)
    // With alphabet "asdf" and 12 matches: p reserves prefixes "d","f" → let's
    // just take whatever the label is for the last element and verify it
    // copies that match.
    guard let lastLabel = state.hint?.labels.last,
          lastLabel.count == 2 else {
      return XCTFail("expected 2-char label")
    }
    // Capture expected text before simulating — state.hint is cleared by the keystroke.
    let expected = state.hint?.matches.last?.text ?? ""
    let actions = simulate(&state, reader: reader, keys: String(lastLabel))
    XCTAssertTrue(actions.contains(where: {
      if case .copyText(let t) = $0 { return t == expected } else { return false }
    }), "should have copied last match (\(expected))")
  }

  func test_line_mode_yanks_whole_line() {
    var (state, reader) = makeState(lines: ["first line", "", "  second  "])
    _ = simulate(&state, reader: reader, keys: "Y")
    let matches = HintDetector.detect(
      lines: ["first line", "", "  second  "],
      source: .lines
    )
    state.applyHintEntry(action: .copy, source: .lines, alphabet: "asdf")
    state.setHintMatches(matches)
    // Only 2 non-empty lines; label "a" should point at bottom line (includes leading whitespace)
    let actions = simulate(&state, reader: reader, keys: "a")
    XCTAssertTrue(actions.contains(.copyText("  second")))
  }
}
