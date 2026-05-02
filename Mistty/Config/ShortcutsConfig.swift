import AppKit
import Foundation
import TOMLKit

struct ShortcutsConfig: Sendable, Equatable {
  /// Resolved chord lists per action (defaults layered with user overrides).
  private(set) var bindings: [ShortcutAction: [Chord]]
  /// Modifier prefix for `cmd+1..cmd+9` style indexed actions.
  var tabIndexModifier: NSEvent.ModifierFlags
  /// Modifier prefix for `ctrl+1..ctrl+9` style indexed actions.
  var sessionIndexModifier: NSEvent.ModifierFlags

  static let `default` = ShortcutsConfig(
    bindings: ShortcutAction.defaults,
    tabIndexModifier: .command,
    sessionIndexModifier: .control
  )

  func chords(for action: ShortcutAction) -> [Chord] {
    bindings[action] ?? []
  }

  /// Primary chord = first binding. Used for the menu's `.keyboardShortcut(...)`
  /// hint; subsequent aliases only fire via the AppKit monitor.
  func primary(for action: ShortcutAction) -> Chord? {
    bindings[action]?.first
  }

  /// Reverse lookup: given a chord, which action does it fire?
  /// Indexed actions (1..9 with the configured modifier) resolve via the
  /// caller's separate digit-key path, not here.
  func action(matching chord: Chord) -> ShortcutAction? {
    for (action, chords) in bindings {
      if chords.contains(chord) { return action }
    }
    return nil
  }

  // NSEvent.ModifierFlags is OptionSet<UInt> without Hashable/Equatable
  // synthesis, so we lower the comparison through rawValue ourselves.
  static func == (lhs: ShortcutsConfig, rhs: ShortcutsConfig) -> Bool {
    lhs.bindings == rhs.bindings
      && lhs.tabIndexModifier.rawValue == rhs.tabIndexModifier.rawValue
      && lhs.sessionIndexModifier.rawValue == rhs.sessionIndexModifier.rawValue
  }
}

enum ShortcutConfigError: Error, Equatable {
  case unknownAction(String)
  case unparseableChord(action: String, raw: String)
  case unparseableModifier(key: String, raw: String)
  case wrongValueType(key: String)
  case conflicts([Conflict])
  case indexedModifierClash(NSEvent.ModifierFlags)

  struct Conflict: Equatable {
    var chord: Chord
    // `actions` is sorted by raw value; the array of conflicts is sorted by the first action's raw value.
    var actions: [ShortcutAction]
  }

  static func == (lhs: ShortcutConfigError, rhs: ShortcutConfigError) -> Bool {
    switch (lhs, rhs) {
    case let (.unknownAction(a), .unknownAction(b)): return a == b
    case let (.unparseableChord(a1, b1), .unparseableChord(a2, b2)):
      return a1 == a2 && b1 == b2
    case let (.unparseableModifier(a1, b1), .unparseableModifier(a2, b2)):
      return a1 == a2 && b1 == b2
    case let (.wrongValueType(a), .wrongValueType(b)): return a == b
    case let (.conflicts(a), .conflicts(b)): return a == b
    case let (.indexedModifierClash(a), .indexedModifierClash(b)):
      return a.rawValue == b.rawValue
    default: return false
    }
  }
}

extension ShortcutsConfig {
  /// Parse the user's `[shortcuts]` table. An empty table yields `.default`.
  static func parse(_ table: TOMLTable) throws -> ShortcutsConfig {
    var bindings = ShortcutAction.defaults
    var tabMod: NSEvent.ModifierFlags = .command
    var sessionMod: NSEvent.ModifierFlags = .control

    for (key, value) in table {
      switch key {
      case "focus_tab_modifier":
        tabMod = try parseModifierOnly(key: key, value: value)
      case "focus_session_modifier":
        sessionMod = try parseModifierOnly(key: key, value: value)
      default:
        guard let action = ShortcutAction(rawValue: key) else {
          throw ShortcutConfigError.unknownAction(key)
        }
        bindings[action] = try parseChordList(action: action, value: value)
      }
    }

    if tabMod.rawValue == sessionMod.rawValue {
      throw ShortcutConfigError.indexedModifierClash(tabMod)
    }

    // Conflict detection: build reverse index, collect collisions.
    var reverse: [Chord: [ShortcutAction]] = [:]
    let sortedActions = bindings.keys.sorted { $0.rawValue < $1.rawValue }
    for action in sortedActions {
      for chord in bindings[action]! {
        reverse[chord, default: []].append(action)
      }
    }
    let conflicts = reverse
      .filter { $1.count > 1 }
      // `actions` is sorted by ShortcutAction.rawValue (we iterate `sortedActions`).
      .map { ShortcutConfigError.Conflict(chord: $0.key, actions: $0.value) }
      .sorted { $0.actions.first!.rawValue < $1.actions.first!.rawValue }
    if !conflicts.isEmpty {
      throw ShortcutConfigError.conflicts(conflicts)
    }

    return ShortcutsConfig(
      bindings: bindings,
      tabIndexModifier: tabMod,
      sessionIndexModifier: sessionMod
    )
  }

  private static func parseChordList(
    action: ShortcutAction,
    value: TOMLValueConvertible
  ) throws -> [Chord] {
    if let s = value.string {
      if s.isEmpty { return [] }
      guard let chord = Chord(s) else {
        throw ShortcutConfigError.unparseableChord(action: action.rawValue, raw: s)
      }
      return [chord]
    }
    if let arr = value.array {
      var out: [Chord] = []
      for entry in arr {
        guard let s = entry.string else {
          throw ShortcutConfigError.wrongValueType(key: action.rawValue)
        }
        if s.isEmpty { continue }
        guard let chord = Chord(s) else {
          throw ShortcutConfigError.unparseableChord(action: action.rawValue, raw: s)
        }
        if !out.contains(chord) { out.append(chord) }
      }
      return out
    }
    throw ShortcutConfigError.wrongValueType(key: action.rawValue)
  }

  private static func parseModifierOnly(
    key: String,
    value: TOMLValueConvertible
  ) throws -> NSEvent.ModifierFlags {
    guard let s = value.string, !s.isEmpty else {
      throw ShortcutConfigError.wrongValueType(key: key)
    }
    var flags: NSEvent.ModifierFlags = []
    let parts = s.lowercased().replacingOccurrences(of: "-", with: "+").split(separator: "+")
    if parts.isEmpty { throw ShortcutConfigError.unparseableModifier(key: key, raw: s) }
    for part in parts {
      switch part {
      case "cmd", "command": flags.insert(.command)
      case "shift":          flags.insert(.shift)
      case "opt", "option", "alt": flags.insert(.option)
      case "ctrl", "control": flags.insert(.control)
      default:
        throw ShortcutConfigError.unparseableModifier(key: key, raw: s)
      }
    }
    return flags
  }
}
