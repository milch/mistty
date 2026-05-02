// Mistty/Config/Chord.swift
import AppKit
import SwiftUI

/// A keyboard chord (modifiers + key). Used both as a SwiftUI menu binding
/// and as an AppKit NSEvent matcher.
struct Chord: Hashable, Sendable {
  enum Key: Hashable, Sendable {
    case character(Character)
    case special(Special)
  }

  enum Special: String, CaseIterable, Sendable {
    case up, down, left, right
    case escape, `return`, tab, space
    case backspace, home, end
    case pageUp = "pageup", pageDown = "pagedown"
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
  }

  let key: Key
  let modifiers: NSEvent.ModifierFlags

  init(key: Key, modifiers: NSEvent.ModifierFlags) {
    self.key = key
    // Constrain to the four user-intent modifiers; arrow events carry .function /
    // .numericPad in their NSEvent flags but we never want those in storage.
    self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
  }

  init?(_ raw: String) {
    let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "+")
    let parts = normalized.split(separator: "+").map(String.init)
    guard let last = parts.last, !last.isEmpty, parts.count >= 2 else { return nil }

    var modifiers: NSEvent.ModifierFlags = []
    for part in parts.dropLast() {
      switch part {
      case "cmd", "command": modifiers.insert(.command)
      case "shift":          modifiers.insert(.shift)
      case "opt", "option", "alt": modifiers.insert(.option)
      case "ctrl", "control": modifiers.insert(.control)
      default: return nil
      }
    }

    if let special = Special(rawValue: last) {
      self.init(key: .special(special), modifiers: modifiers)
    } else if last.count == 1, let ch = last.first {
      self.init(key: .character(ch), modifiers: modifiers)
    } else {
      return nil
    }
  }

  // NSEvent.ModifierFlags is OptionSet<UInt> but doesn't ship with Hashable
  // conformance, so synthesise via rawValue.
  static func == (lhs: Chord, rhs: Chord) -> Bool {
    lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(key)
    hasher.combine(modifiers.rawValue)
  }
}

extension Chord {
  /// SwiftUI `(KeyEquivalent, EventModifiers)` pair for `.keyboardShortcut`.
  func swiftUI() -> (KeyEquivalent, EventModifiers) {
    let mods: EventModifiers = {
      var m: EventModifiers = []
      if modifiers.contains(.command) { m.insert(.command) }
      if modifiers.contains(.shift)   { m.insert(.shift) }
      if modifiers.contains(.option)  { m.insert(.option) }
      if modifiers.contains(.control) { m.insert(.control) }
      return m
    }()
    let eq: KeyEquivalent
    switch key {
    case .character(let c): eq = KeyEquivalent(c)
    case .special(let s):
      switch s {
      case .up: eq = .upArrow
      case .down: eq = .downArrow
      case .left: eq = .leftArrow
      case .right: eq = .rightArrow
      case .escape: eq = .escape
      case .return: eq = .return
      case .tab: eq = .tab
      case .space: eq = .space
      case .backspace: eq = .delete
      case .home: eq = .home
      case .end: eq = .end
      case .pageUp: eq = .pageUp
      case .pageDown: eq = .pageDown
      case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
        // SwiftUI's KeyEquivalent has no function-key constants; fall back to
        // the character representation. Function keys can still be matched at
        // the AppKit monitor layer via keyCode.
        eq = KeyEquivalent(Character(s.rawValue))
      }
    }
    return (eq, mods)
  }

  /// AppKit matcher. Special keys match by `keyCode` (layout-independent);
  /// character keys match `charactersIgnoringModifiers` (lowercased).
  func matches(_ event: NSEvent) -> Bool {
    let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    guard event.modifierFlags.intersection(mask) == modifiers else { return false }
    switch key {
    case .character(let c):
      let lowered = String(c).lowercased()
      return event.charactersIgnoringModifiers?.lowercased() == lowered
    case .special(let s):
      return event.keyCode == s.keyCode
    }
  }
}

extension Chord.Special {
  /// macOS virtual keycodes from `Carbon/HIToolbox/Events.h`. Stable across
  /// keyboard layouts — bracket characters intentionally aren't here because
  /// users type them as characters, and shift-bracket on US produces "{"/"}".
  var keyCode: UInt16 {
    switch self {
    case .up: return 126
    case .down: return 125
    case .left: return 123
    case .right: return 124
    case .escape: return 53
    case .return: return 36
    case .tab: return 48
    case .space: return 49
    case .backspace: return 51
    case .home: return 115
    case .end: return 119
    case .pageUp: return 116
    case .pageDown: return 121
    case .f1: return 122
    case .f2: return 120
    case .f3: return 99
    case .f4: return 118
    case .f5: return 96
    case .f6: return 97
    case .f7: return 98
    case .f8: return 100
    case .f9: return 101
    case .f10: return 109
    case .f11: return 103
    case .f12: return 111
    }
  }
}
