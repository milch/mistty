// MisttyTests/Config/ChordTests.swift
import AppKit
import SwiftUI
import Testing
@testable import Mistty

struct ChordTests {
  @Test func parsesSimpleCommandChord() {
    let chord = Chord("cmd+t")
    #expect(chord != nil)
    #expect(chord?.modifiers == .command)
    #expect(chord?.key == .character("t"))
  }

  @Test func parsesMultipleModifiers() {
    let chord = Chord("cmd+shift+w")
    #expect(chord?.modifiers == [.command, .shift])
    #expect(chord?.key == .character("w"))
  }

  @Test func acceptsHyphenSeparator() {
    let a = Chord("cmd+t")
    let b = Chord("cmd-t")
    #expect(a == b)
  }

  @Test func isCaseInsensitive() {
    #expect(Chord("CMD+T") == Chord("cmd+t"))
  }

  @Test func acceptsModifierAliases() {
    #expect(Chord("command+t") == Chord("cmd+t"))
    #expect(Chord("option+t")  == Chord("opt+t"))
    #expect(Chord("alt+t")     == Chord("opt+t"))
    #expect(Chord("control+t") == Chord("ctrl+t"))
  }

  @Test func rejectsUnknownModifier() {
    #expect(Chord("hyper+t") == nil)
  }

  @Test func rejectsEmptyString() {
    // "" is the disable sentinel — handled at a higher layer, not by Chord.
    #expect(Chord("") == nil)
  }

  @Test func rejectsBareModifier() {
    #expect(Chord("cmd+") == nil)
    #expect(Chord("cmd")  == nil)
  }

  @Test func rejectsMultiCharacterKey() {
    // "ab" is ambiguous — the only multi-char tokens we accept are special keys.
    #expect(Chord("cmd+ab") == nil)
  }
}

extension ChordTests {
  @Test func parsesArrowSpecialKeys() {
    #expect(Chord("cmd+up")?.key   == .special(.up))
    #expect(Chord("cmd+down")?.key == .special(.down))
    #expect(Chord("cmd+left")?.key == .special(.left))
    #expect(Chord("cmd+right")?.key == .special(.right))
  }

  @Test func parsesBracketCharacters() {
    // Brackets are characters, not special keys — but they're hashable distinctly
    // from "{" so config "cmd+]" and a shifted "cmd+]" don't alias.
    #expect(Chord("cmd+]")?.key == .character("]"))
    #expect(Chord("cmd+shift+]")?.key == .character("]"))
  }

  @Test func swiftUIMappingForCharacter() {
    let (eq, mods) = Chord("cmd+shift+t")!.swiftUI()
    #expect(eq == KeyEquivalent("t"))
    #expect(mods == [.command, .shift])
  }

  @Test func swiftUIMappingForSpecialKey() {
    let (eq, mods) = Chord("cmd+up")!.swiftUI()
    #expect(eq == .upArrow)
    #expect(mods == .command)
  }

  @Test func matchesEventByCharacter() {
    let chord = Chord("cmd+shift+t")!
    let event = makeKeyDown(
      keyCode: 17, // "t" on US layout
      characters: "t",
      flags: [.command, .shift]
    )
    #expect(chord.matches(event))
  }

  @Test func matchesEventBySpecialKeyCode() {
    let chord = Chord("cmd+up")!
    // 126 == kVK_UpArrow; charactersIgnoringModifiers is the literal arrow glyph.
    let event = makeKeyDown(
      keyCode: 126,
      characters: "\u{F700}",
      flags: [.command, .function, .numericPad]
    )
    #expect(chord.matches(event))
  }

  @Test func mismatchOnDifferentModifiers() {
    let chord = Chord("cmd+t")!
    let event = makeKeyDown(keyCode: 17, characters: "t", flags: [.command, .shift])
    #expect(!chord.matches(event))
  }
}

// MARK: - NSEvent factory for tests
private func makeKeyDown(
  keyCode: UInt16,
  characters: String,
  flags: NSEvent.ModifierFlags
) -> NSEvent {
  return NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: flags,
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: characters,
    charactersIgnoringModifiers: characters,
    isARepeat: false,
    keyCode: keyCode
  )!
}
