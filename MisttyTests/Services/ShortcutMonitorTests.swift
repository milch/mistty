import AppKit
import Testing
@testable import Mistty

struct ShortcutMonitorTests {
  // Test fixtures
  private func makeContext(
    isTerminalKey: Bool = true,
    firstResponderIsText: Bool = false,
    inModalMode: Bool = false
  ) -> ShortcutMonitor.Context {
    ShortcutMonitor.Context(
      isTerminalWindowKey: { isTerminalKey },
      firstResponderIsTextField: { firstResponderIsText },
      inModalMode: { inModalMode }
    )
  }

  private func makeEvent(_ chord: Chord) -> NSEvent {
    let chars: String
    let keyCode: UInt16
    switch chord.key {
    case .character(let c):
      chars = String(c).lowercased()
      keyCode = 0  // not used for character matching
    case .special(let s):
      chars = "\u{F700}"
      keyCode = s.keyCode
    }
    return NSEvent.keyEvent(
      with: .keyDown, location: .zero,
      modifierFlags: chord.modifiers,
      timestamp: 0, windowNumber: 0, context: nil,
      characters: chars, charactersIgnoringModifiers: chars,
      isARepeat: false, keyCode: keyCode
    )!
  }

  @Test func dispatchesActionForBoundChord() {
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(config: cfg, context: makeContext())
    let event = makeEvent(Chord("cmd+t")!)
    let result = monitor.handle(event: event)
    #expect(result.consumed)
    #expect(result.action == .newTab)
  }

  @Test func passesThroughUnboundChord() {
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(config: cfg, context: makeContext())
    let event = makeEvent(Chord("cmd+ctrl+f7")!)
    let result = monitor.handle(event: event)
    #expect(!result.consumed)
    #expect(result.action == nil)
  }

  @Test func passesThroughWhenNotTerminalKey() {
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(
      config: cfg, context: makeContext(isTerminalKey: false))
    let event = makeEvent(Chord("cmd+t")!)
    let result = monitor.handle(event: event)
    #expect(!result.consumed)
  }

  @Test func windowModePassesThroughTextResponder() {
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(
      config: cfg, context: makeContext(firstResponderIsText: true))
    let event = makeEvent(Chord("cmd+x")!)
    let result = monitor.handle(event: event)
    #expect(!result.consumed)
  }

  @Test func nextTabDisabledInModalMode() {
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(
      config: cfg, context: makeContext(inModalMode: true))
    let event = makeEvent(Chord("cmd+]")!)
    let result = monitor.handle(event: event)
    #expect(!result.consumed)
  }

  @Test func newTabFiresEvenInModalMode() {
    // newTab has no disabledInModalModes policy, so a modal session manager
    // open shouldn't suppress cmd+t.
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(
      config: cfg, context: makeContext(inModalMode: true))
    let event = makeEvent(Chord("cmd+t")!)
    let result = monitor.handle(event: event)
    #expect(result.consumed)
    #expect(result.action == .newTab)
  }

  @Test func indexedTabModifierResolves() {
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(config: cfg, context: makeContext())
    // cmd+3 → focus tab index 3 (1-based).
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero,
      modifierFlags: .command,
      timestamp: 0, windowNumber: 0, context: nil,
      characters: "3", charactersIgnoringModifiers: "3",
      isARepeat: false, keyCode: 20  // "3"
    )!
    let result = monitor.handle(event: event)
    #expect(result.consumed)
    #expect(result.indexedAction == .focusTab(index: 3))
  }

  @Test func indexedSessionModifierResolves() {
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(config: cfg, context: makeContext())
    // ctrl+5 → focus session index 5.
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero,
      modifierFlags: .control,
      timestamp: 0, windowNumber: 0, context: nil,
      characters: "5", charactersIgnoringModifiers: "5",
      isARepeat: false, keyCode: 23  // "5"
    )!
    let result = monitor.handle(event: event)
    #expect(result.consumed)
    #expect(result.indexedAction == .focusSession(index: 5))
  }

  @Test func indexedDigitOutsideOneToNineIgnored() {
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(config: cfg, context: makeContext())
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero,
      modifierFlags: .command,
      timestamp: 0, windowNumber: 0, context: nil,
      characters: "0", charactersIgnoringModifiers: "0",
      isARepeat: false, keyCode: 29
    )!
    let result = monitor.handle(event: event)
    #expect(!result.consumed)
  }

  @Test func shiftBracketDispatchesViaKeyCode() {
    // cmd+shift+] → next_session. The OS sends "}" as
    // charactersIgnoringModifiers because shift IS applied; Chord(event:)
    // must map keyCode 30 back to "]" so the user's `cmd+shift+]` config
    // matches.
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(config: cfg, context: makeContext())
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero,
      modifierFlags: [.command, .shift],
      timestamp: 0, windowNumber: 0, context: nil,
      characters: "}", charactersIgnoringModifiers: "}",
      isARepeat: false, keyCode: 30  // kVK_ANSI_RightBracket
    )!
    let result = monitor.handle(event: event)
    #expect(result.consumed)
    #expect(result.action == .nextSession)
  }

  @Test func shiftLeftBracketDispatchesViaKeyCode() {
    // cmd+shift+[ → prev_session.
    let cfg = ShortcutsConfig.default
    let monitor = ShortcutMonitor(config: cfg, context: makeContext())
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero,
      modifierFlags: [.command, .shift],
      timestamp: 0, windowNumber: 0, context: nil,
      characters: "{", charactersIgnoringModifiers: "{",
      isARepeat: false, keyCode: 33  // kVK_ANSI_LeftBracket
    )!
    let result = monitor.handle(event: event)
    #expect(result.consumed)
    #expect(result.action == .prevSession)
  }
}
