import Testing
@testable import Mistty
import MisttyShared
import Foundation
import TOMLKit

struct MisttyConfigShortcutsTests {
  @Test func shortcutsTableParses() throws {
    let cfg = try MisttyConfig.parse("""
    [shortcuts]
    new_tab = "cmd+shift+n"
    """)
    #expect(cfg.shortcuts.chords(for: .newTab) == [Chord("cmd+shift+n")!])
  }

  @Test func shortcutsRoundTripOmitsDefaults() throws {
    var cfg = MisttyConfig()
    cfg.shortcuts = try ShortcutsConfig.parse(TOMLTable(string: """
    new_tab = "cmd+shift+n"
    """))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-shortcut-roundtrip-\(UUID()).toml")
    try cfg.save(to: url)
    let written = try String(contentsOf: url, encoding: .utf8)
    #expect(written.contains("[shortcuts]"))
    #expect(written.contains(#"new_tab = "cmd+shift+n""#))
    // Untouched defaults must NOT be emitted.
    #expect(!written.contains("close_pane = "))
    let reparsed = try MisttyConfig.parse(written)
    #expect(reparsed.shortcuts.chords(for: .newTab) == [Chord("cmd+shift+n")!])
    #expect(reparsed.shortcuts.chords(for: .closePane) == [Chord("cmd+w")!])
  }

  @Test func shortcutConflictBubblesUpFromMisttyConfig() {
    #expect(throws: ShortcutConfigError.self) {
      try MisttyConfig.parse("""
      [shortcuts]
      new_tab = "cmd+t"
      session_manager = "cmd+t"
      """)
    }
  }
}
