import Testing
import TOMLKit
@testable import Mistty

struct ShortcutsConfigTests {
  // MARK: - Layered defaults
  @Test func emptyTableYieldsDefaults() throws {
    let cfg = try parse("")
    #expect(cfg.chords(for: .newTab) == ShortcutAction.defaults[.newTab])
    #expect(cfg.tabIndexModifier == .command)
    #expect(cfg.sessionIndexModifier == .control)
  }

  @Test func userOverrideReplacesDefaultForOneAction() throws {
    let cfg = try parse("""
    [shortcuts]
    new_tab = "cmd+shift+n"
    """)
    #expect(cfg.chords(for: .newTab) == [Chord("cmd+shift+n")!])
    #expect(cfg.chords(for: .closePane) == [Chord("cmd+w")!])
  }

  @Test func emptyStringDisablesADefault() throws {
    let cfg = try parse("""
    [shortcuts]
    rename_tab = ""
    """)
    #expect(cfg.chords(for: .renameTab) == [])
  }

  @Test func arrayValueBindsMultipleChords() throws {
    let cfg = try parse("""
    [shortcuts]
    new_tab = ["cmd+t", "cmd+n"]
    """)
    #expect(cfg.chords(for: .newTab) == [Chord("cmd+t")!, Chord("cmd+n")!])
  }

  @Test func indexedModifiersOverride() throws {
    let cfg = try parse("""
    [shortcuts]
    focus_tab_modifier = "ctrl"
    focus_session_modifier = "cmd+shift"
    """)
    #expect(cfg.tabIndexModifier == .control)
    #expect(cfg.sessionIndexModifier == [.command, .shift])
  }

  // MARK: - Errors
  @Test func unknownActionKeyThrows() throws {
    #expect(throws: ShortcutConfigError.self) {
      try parse("""
      [shortcuts]
      bogus_action = "cmd+t"
      """)
    }
  }

  @Test func unparseableChordThrows() throws {
    #expect(throws: ShortcutConfigError.self) {
      try parse("""
      [shortcuts]
      new_tab = "hyper+t"
      """)
    }
  }

  @Test func conflictBetweenTwoActionsThrows() throws {
    do {
      _ = try parse("""
      [shortcuts]
      new_tab = "cmd+t"
      session_manager = "cmd+t"
      """)
      Issue.record("expected conflict error")
    } catch let ShortcutConfigError.conflicts(items) {
      #expect(items.count == 1)
      let actions = Set(items.first!.actions)
      #expect(actions == [.newTab, .sessionManager])
    }
  }

  @Test func sameChordOnSameActionIsDeduped() throws {
    let cfg = try parse("""
    [shortcuts]
    new_tab = ["cmd+t", "cmd+t"]
    """)
    #expect(cfg.chords(for: .newTab) == [Chord("cmd+t")!])
  }

  @Test func indexedModifiersClashThrows() throws {
    #expect(throws: ShortcutConfigError.self) {
      try parse("""
      [shortcuts]
      focus_tab_modifier = "cmd"
      focus_session_modifier = "cmd"
      """)
    }
  }

  // MARK: - Reverse lookup
  @Test func lookupResolvesOverriddenChord() throws {
    let cfg = try parse("""
    [shortcuts]
    new_tab = "cmd+shift+n"
    """)
    #expect(cfg.action(matching: Chord("cmd+shift+n")!) == .newTab)
    #expect(cfg.action(matching: Chord("cmd+t")!) == nil)
  }

  @Test func unparseableModifierThrows() throws {
    #expect(throws: ShortcutConfigError.self) {
      try parse("""
      [shortcuts]
      focus_tab_modifier = "hyper"
      """)
    }
  }

  @Test func wrongValueTypeOnModifierKeyThrows() throws {
    #expect(throws: ShortcutConfigError.self) {
      try parse("""
      [shortcuts]
      focus_tab_modifier = 42
      """)
    }
  }

  @Test func wrongValueTypeOnActionKeyThrows() throws {
    #expect(throws: ShortcutConfigError.self) {
      try parse("""
      [shortcuts]
      new_tab = 42
      """)
    }
  }

  @Test func wrongValueTypeInsideActionArrayThrows() throws {
    #expect(throws: ShortcutConfigError.self) {
      try parse("""
      [shortcuts]
      new_tab = ["cmd+t", 42]
      """)
    }
  }
}

private func parse(_ toml: String) throws -> ShortcutsConfig {
  let table = try TOMLTable(string: toml)
  return try ShortcutsConfig.parse(table["shortcuts"]?.table ?? TOMLTable())
}
