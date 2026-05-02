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
