// Mistty/Config/Chord.swift
import AppKit
import SwiftUI

/// A keyboard chord (modifiers + key). Used both as a SwiftUI menu binding
/// and as an AppKit NSEvent matcher.
struct Chord: Hashable {
  enum Key: Hashable {
    case character(Character)
    case special(Special)
  }

  enum Special: String, CaseIterable {
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
