import AppKit
import Foundation

/// A single config-driven AppKit local monitor. Replaces the three legacy
/// monitors (`closeMonitor`, `altShortcutMonitor`, `windowModeShortcutMonitor`)
/// from `ContentView` with one lookup table-driven dispatcher.
///
/// The pure handler `handle(event:)` is extracted so tests can drive it
/// directly with synthesized `NSEvent`s; `install()` wraps it in
/// `NSEvent.addLocalMonitorForEvents` and posts notifications on consume.
final class ShortcutMonitor {
  /// Caller-supplied window/state queries. Recomputed on every keyDown
  /// rather than cached, since "key window" / "first responder" / "in modal
  /// mode" all change as the user navigates.
  struct Context {
    var isTerminalWindowKey: () -> Bool
    var firstResponderIsTextField: () -> Bool
    var inModalMode: () -> Bool
  }

  enum IndexedAction: Equatable {
    case focusTab(index: Int)       // 1-based
    case focusSession(index: Int)   // 1-based
  }

  struct HandleResult {
    var consumed: Bool
    var action: ShortcutAction?
    var indexedAction: IndexedAction?
  }

  private var config: ShortcutsConfig
  private let context: Context
  private var monitor: Any?

  init(config: ShortcutsConfig, context: Context) {
    self.config = config
    self.context = context
  }

  func updateConfig(_ new: ShortcutsConfig) { self.config = new }

  /// Pure handler — testable. Returns whether to consume + which action fired.
  /// Side effects (notification posts) happen in `install()`'s closure.
  func handle(event: NSEvent) -> HandleResult {
    guard context.isTerminalWindowKey() else {
      return HandleResult(consumed: false, action: nil, indexedAction: nil)
    }

    // Indexed-action match: digit 1..9 with the configured modifier prefix.
    let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    let flags = event.modifierFlags.intersection(mask)
    let tabMatch = flags.rawValue == config.tabIndexModifier.rawValue
    let sessionMatch = flags.rawValue == config.sessionIndexModifier.rawValue
    if tabMatch || sessionMatch {
      if let chars = event.charactersIgnoringModifiers,
         chars.count == 1, let digit = Int(chars), (1...9).contains(digit)
      {
        let indexed: IndexedAction = tabMatch
          ? .focusTab(index: digit)
          : .focusSession(index: digit)
        return HandleResult(consumed: true, action: nil, indexedAction: indexed)
      }
    }

    // Build a Chord for the incoming event, then look up the action.
    guard let chord = Chord(event: event) else {
      return HandleResult(consumed: false, action: nil, indexedAction: nil)
    }
    guard let action = config.action(matching: chord) else {
      return HandleResult(consumed: false, action: nil, indexedAction: nil)
    }
    let policy = action.policy
    if policy.passThroughWhenTextResponder, context.firstResponderIsTextField() {
      return HandleResult(consumed: false, action: nil, indexedAction: nil)
    }
    if policy.disabledInModalModes, context.inModalMode() {
      return HandleResult(consumed: false, action: nil, indexedAction: nil)
    }
    return HandleResult(consumed: true, action: action, indexedAction: nil)
  }

  /// Install the AppKit local monitor. Call from `ContentView.onAppear`.
  func install() {
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self else { return event }
      let result = self.handle(event: event)
      if result.consumed {
        if let action = result.action {
          NotificationCenter.default.post(name: action.notificationName, object: nil)
        } else if let indexed = result.indexedAction {
          switch indexed {
          case .focusTab(let i):
            NotificationCenter.default.post(
              name: .misttyFocusTabByIndex, object: nil,
              userInfo: ["index": i - 1])
          case .focusSession(let i):
            NotificationCenter.default.post(
              name: .misttyFocusSessionByIndex, object: nil,
              userInfo: ["index": i - 1])
          }
        }
        return nil
      }
      return event
    }
    self.monitor = monitor
  }

  func uninstall() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}

// Build a Chord straight from an NSEvent (used at the matcher boundary).
extension Chord {
  init?(event: NSEvent) {
    let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    let mods = event.modifierFlags.intersection(mask)
    // Special key by keyCode first (arrows, function keys, escape, etc.).
    if let s = Special.allCases.first(where: { $0.keyCode == event.keyCode }) {
      self.init(key: .special(s), modifiers: mods)
      return
    }
    // For punctuation that shifts to a different glyph (`]` → `}`, `[` → `{`),
    // map back to the unshifted character via keyCode so that chords like
    // "cmd+shift+]" match the user's config which says `]`, not `}`.
    if let unshifted = Self.unshiftedPunctuation(for: event.keyCode) {
      self.init(key: .character(unshifted), modifiers: mods)
      return
    }
    // Character path. `charactersIgnoringModifiers` still applies shift, so
    // for letters/digits this reads correctly (cmd+a → "a"), and for
    // punctuation the case above already short-circuited.
    guard let chars = event.charactersIgnoringModifiers?.lowercased(),
          chars.count == 1, let c = chars.first
    else { return nil }
    self.init(key: .character(c), modifiers: mods)
  }

  /// Map well-known punctuation keyCodes to their unshifted character.
  /// These are the keys whose character changes under shift (`]` → `}`),
  /// where `charactersIgnoringModifiers` would otherwise produce the
  /// shifted glyph and break a `cmd+shift+]` config match.
  private static func unshiftedPunctuation(for keyCode: UInt16) -> Character? {
    switch keyCode {
    case 30: return "]"   // kVK_ANSI_RightBracket
    case 33: return "["   // kVK_ANSI_LeftBracket
    default: return nil
    }
  }
}
