# Configurable Keyboard Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive Mistty's global / menu-bar keyboard shortcuts from a `[shortcuts]` block in `~/.config/mistty/config.toml`, ship the four PLAN.md behavior changes (close-tab → cmd+ctrl+w, close-window → cmd+shift+w, session-cycle → cmd+opt+arrows, session-swap → cmd+shift+arrows), and collapse today's three NSEvent monitors into one config-driven router.

**Architecture:** A new `Chord` value type parses chord strings ("cmd+shift+w"), exposes a SwiftUI `KeyEquivalent`+`EventModifiers` pair for menu binding *and* an AppKit `NSEvent` matcher for the local monitor. A `ShortcutAction` enum lists every configurable action with hard-coded defaults; user `[shortcuts]` entries override per-action with conflict detection. A single `ShortcutMonitor` replaces `closeMonitor`, `altShortcutMonitor`, and `windowModeShortcutMonitor` — looks up `(modifiers, key) → ShortcutAction`, applies a per-action `FirePolicy`, posts the existing notification or passes the event through. Menu `.keyboardShortcut(...)` calls read the registry's primary chord and rebuild on `.misttyConfigDidReload`.

**Tech Stack:** Swift 6, SwiftUI + AppKit hybrid, TOMLKit, swift-testing for unit tests, the existing `MisttyConfig.reload()` live-reload pipeline.

**Spec:** `docs/superpowers/specs/2026-04-28-keyboard-shortcuts-config-design.md`.

---

## File Structure

**New files:**
- `Mistty/Config/Chord.swift` — `Chord` struct, `Chord.Key`, `Chord.Special`, parser, `swiftUI()`, `matches(NSEvent)`.
- `Mistty/Config/ShortcutAction.swift` — `ShortcutAction` enum, `defaults` table, `FirePolicy` struct + `policy` property, `Notification.Name` mapping.
- `Mistty/Config/ShortcutsConfig.swift` — `ShortcutsConfig` value type holding `[ShortcutAction: [Chord]]` + indexed-action modifiers, `ShortcutConfigError`, parser from `TOMLTable`, conflict detection.
- `Mistty/Services/ShortcutMonitor.swift` — single `NSEvent.addLocalMonitorForEvents` consumer, lookup + policy gating + notification post.
- `MisttyTests/Config/ChordTests.swift`
- `MisttyTests/Config/ShortcutActionTests.swift`
- `MisttyTests/Config/ShortcutsConfigTests.swift`
- `MisttyTests/Services/ShortcutMonitorTests.swift`

**Modified files:**
- `Mistty/Config/MisttyConfig.swift` — add `shortcuts: ShortcutsConfig`, parse `[shortcuts]`, save round-trip; throw `ShortcutConfigError` from `parse(_:)`.
- `Mistty/App/MisttyApp.swift` — drop the inline `parseShortcutKey`/`parseShortcutModifiers`; menu Buttons read `config.shortcuts.primary(for:)`; add a `Close Window` menu item; add `.misttyCloseWindow` notification.
- `Mistty/App/ContentView.swift` — delete `closeMonitor`, `altShortcutMonitor`, `windowModeShortcutMonitor` (and their install/remove helpers); install `ShortcutMonitor` from `onAppear`. `windowModeMonitor`, `copyModeMonitor`, `ctrlNavMonitor`, and the session-manager `eventMonitor` stay (in-mode keys are out of scope).
- `Mistty/App/WindowRootView.swift` — handle `.misttyCloseWindow`.
- `Mistty/Models/PopupDefinition.swift` — store `shortcut: Chord?` instead of `String?`; keep an extra `shortcutRaw: String?` so Settings UI and `save()` round-trip the original text.
- `Mistty/Views/Settings/SettingsView.swift` — popup shortcut field bound to `shortcutRaw` (no behavior change for users; just keeps the parsed/raw split clean).
- `docs/config-example.toml` — add fully annotated `[shortcuts]` block.

**Deferred (not in this plan):**
- Settings UI for `[shortcuts]` (deferred to PLAN.md's preference-pane redesign).
- In-mode keys (window-mode hjkl/r/b/m/1-5/z, copy-mode vim grammar).
- Per-popup shortcut grammar changes (popups still use the same chord grammar via the new `Chord` parser; the grammar gains arrow + special-key support as a side effect).

---

## Task 1: Chord type — character-key parsing & matching

**Files:**
- Create: `Mistty/Config/Chord.swift`
- Test: `MisttyTests/Config/ChordTests.swift`

- [ ] **Step 1: Write the failing test for the character-key parser**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ChordTests 2>&1 | tee /tmp/mistty-test-task1.log | tail -30`
Expected: FAIL — `Chord` type undefined.

- [ ] **Step 3: Implement minimal `Chord` covering character keys only**

```swift
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
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ChordTests 2>&1 | tee /tmp/mistty-test-task1.log | tail -20`
Expected: PASS for all 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Config/Chord.swift MisttyTests/Config/ChordTests.swift
git commit -m "feat: add Chord value type with character-key parser

First slice of the configurable keyboard shortcuts work. Chord parses
strings like 'cmd+shift+w', supports +/- separators, modifier aliases,
and case-insensitive input. Special-key matching and SwiftUI/NSEvent
adapters land in follow-up tasks."
```

---

## Task 2: Chord — special keys & adapters (`swiftUI()`, `matches`)

**Files:**
- Modify: `Mistty/Config/Chord.swift`
- Modify: `MisttyTests/Config/ChordTests.swift`

- [ ] **Step 1: Add failing tests for special keys + adapters**

Append to `MisttyTests/Config/ChordTests.swift`:

```swift
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
  // Use a synthesized NSEvent. Times/locations are arbitrary; we only read flags,
  // keyCode, and charactersIgnoringModifiers in Chord.matches(_:).
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
```

- [ ] **Step 2: Run tests, expect failure on `swiftUI()` / `matches`**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ChordTests 2>&1 | tee /tmp/mistty-test-task2.log | tail -30`
Expected: FAIL — `swiftUI()` and `matches(_:)` not defined.

- [ ] **Step 3: Implement adapters and special-key matching**

Append to `Mistty/Config/Chord.swift`:

```swift
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
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ChordTests 2>&1 | tee /tmp/mistty-test-task2.log | tail -20`
Expected: PASS for all 16 tests.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Config/Chord.swift MisttyTests/Config/ChordTests.swift
git commit -m "feat: Chord adapters for SwiftUI menu + AppKit NSEvent

swiftUI() returns the (KeyEquivalent, EventModifiers) pair for menu
binding; matches(NSEvent) is the local-monitor predicate. Special keys
(arrows, function keys, escape, return, tab, etc.) match by keyCode so
shift-bracket and layout-dependent characters can't trip up matching."
```

---

## Task 3: ShortcutAction enum + defaults

**Files:**
- Create: `Mistty/Config/ShortcutAction.swift`
- Test: `MisttyTests/Config/ShortcutActionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MisttyTests/Config/ShortcutActionTests.swift
import Testing
@testable import Mistty

struct ShortcutActionTests {
  @Test func everyActionHasADefaultEntry() {
    for action in ShortcutAction.allCases {
      let chords = ShortcutAction.defaults[action]
      #expect(chords != nil, "\(action.rawValue) missing in defaults")
    }
  }

  @Test func reloadConfigDefaultIsExplicitlyEmpty() {
    #expect(ShortcutAction.defaults[.reloadConfig] == [])
  }

  @Test func defaultClosePaneIsCmdW() {
    #expect(ShortcutAction.defaults[.closePane] == [Chord("cmd+w")!])
  }

  @Test func defaultCloseTabIsCmdCtrlW() {
    // PLAN.md change: was cmd+shift+w.
    #expect(ShortcutAction.defaults[.closeTab] == [Chord("cmd+ctrl+w")!])
  }

  @Test func defaultCloseWindowIsCmdShiftW() {
    // PLAN.md change: new action.
    #expect(ShortcutAction.defaults[.closeWindow] == [Chord("cmd+shift+w")!])
  }

  @Test func defaultNextSessionIsCmdOptDownPlusBracket() {
    #expect(
      ShortcutAction.defaults[.nextSession]
        == [Chord("cmd+opt+down")!, Chord("cmd+shift+]")!]
    )
  }

  @Test func defaultSwapSessionDownIsCmdShiftDownPlusBracket() {
    #expect(
      ShortcutAction.defaults[.swapSessionDown]
        == [Chord("cmd+shift+down")!, Chord("cmd+opt+]")!]
    )
  }

  @Test func eachActionMapsToANotificationName() {
    for action in ShortcutAction.allCases {
      _ = action.notificationName  // must compile / not crash
    }
  }

  @Test func policyForCloseActionsRequiresTerminalWindow() {
    #expect(ShortcutAction.closePane.policy.requiresTerminalWindowKey)
    #expect(ShortcutAction.closeTab.policy.requiresTerminalWindowKey)
    #expect(ShortcutAction.closeWindow.policy.requiresTerminalWindowKey)
  }

  @Test func policyForWindowModePassesThroughTextResponder() {
    #expect(ShortcutAction.windowMode.policy.passThroughWhenTextResponder)
  }

  @Test func policyForArrowSessionAndTabActionsDisabledInModalModes() {
    for a: ShortcutAction in [
      .nextTab, .prevTab, .nextSession, .prevSession,
      .swapSessionDown, .swapSessionUp,
    ] {
      #expect(a.policy.disabledInModalModes, "\(a.rawValue) should be modal-disabled")
    }
  }
}
```

- [ ] **Step 2: Run, expect fail**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ShortcutActionTests 2>&1 | tee /tmp/mistty-test-task3.log | tail -25`
Expected: FAIL — `ShortcutAction` undefined.

- [ ] **Step 3: Implement**

```swift
// Mistty/Config/ShortcutAction.swift
import Foundation

enum ShortcutAction: String, CaseIterable, Hashable {
  case newTab               = "new_tab"
  case newTabPlain          = "new_tab_plain"
  case closePane            = "close_pane"
  case closeTab             = "close_tab"
  case closeWindow          = "close_window"
  case windowMode           = "window_mode"
  case copyMode             = "copy_mode"
  case yankHints            = "yank_hints"
  case sessionManager       = "session_manager"
  case toggleSidebar        = "toggle_sidebar"
  case toggleTabBar         = "toggle_tab_bar"
  case reloadConfig         = "reload_config"
  case splitHorizontal      = "split_horizontal"
  case splitHorizontalPlain = "split_horizontal_plain"
  case splitVertical        = "split_vertical"
  case splitVerticalPlain   = "split_vertical_plain"
  case reopenClosedWindow   = "reopen_closed_window"
  case renameTab            = "rename_tab"
  case renameSession        = "rename_session"
  case nextTab              = "next_tab"
  case prevTab              = "prev_tab"
  case nextSession          = "next_session"
  case prevSession          = "prev_session"
  case swapSessionDown      = "swap_session_down"
  case swapSessionUp        = "swap_session_up"
}

extension ShortcutAction {
  static let defaults: [ShortcutAction: [Chord]] = [
    .newTab:               [Chord("cmd+t")!],
    .newTabPlain:          [Chord("cmd+opt+t")!],
    .closePane:            [Chord("cmd+w")!],
    .closeTab:             [Chord("cmd+ctrl+w")!],
    .closeWindow:          [Chord("cmd+shift+w")!],
    .windowMode:           [Chord("cmd+x")!],
    .copyMode:             [Chord("cmd+shift+c")!],
    .yankHints:            [Chord("cmd+shift+y")!],
    .sessionManager:       [Chord("cmd+j")!],
    .toggleSidebar:        [Chord("cmd+s")!],
    .toggleTabBar:         [Chord("cmd+shift+b")!],
    .reloadConfig:         [],
    .splitHorizontal:      [Chord("cmd+d")!],
    .splitHorizontalPlain: [Chord("cmd+opt+d")!],
    .splitVertical:        [Chord("cmd+shift+d")!],
    .splitVerticalPlain:   [Chord("cmd+shift+opt+d")!],
    .reopenClosedWindow:   [Chord("cmd+shift+t")!],
    .renameTab:            [Chord("cmd+shift+r")!],
    .renameSession:        [Chord("cmd+opt+r")!],
    .nextTab:              [Chord("cmd+]")!, Chord("cmd+down")!],
    .prevTab:              [Chord("cmd+[")!, Chord("cmd+up")!],
    .nextSession:          [Chord("cmd+opt+down")!, Chord("cmd+shift+]")!],
    .prevSession:          [Chord("cmd+opt+up")!,   Chord("cmd+shift+[")!],
    .swapSessionDown:      [Chord("cmd+shift+down")!, Chord("cmd+opt+]")!],
    .swapSessionUp:        [Chord("cmd+shift+up")!,   Chord("cmd+opt+[")!],
  ]
}

struct FirePolicy: Equatable {
  /// Every shortcut today gates on this. Carried as a field so future actions
  /// (e.g. global hotkeys) can opt out cleanly.
  var requiresTerminalWindowKey: Bool = true
  /// Cmd+X must fall through to system Cut when a TextField has focus.
  var passThroughWhenTextResponder: Bool = false
  /// Disable while window-mode / copy-mode / session-manager owns input.
  var disabledInModalModes: Bool = false
}

extension ShortcutAction {
  var policy: FirePolicy {
    switch self {
    case .windowMode:
      return FirePolicy(passThroughWhenTextResponder: true)
    case .nextTab, .prevTab,
         .nextSession, .prevSession,
         .swapSessionDown, .swapSessionUp:
      return FirePolicy(disabledInModalModes: true)
    default:
      return FirePolicy()
    }
  }

  var notificationName: Notification.Name {
    switch self {
    case .newTab:               return .misttyNewTab
    case .newTabPlain:          return .misttyNewTabPlain
    case .closePane:            return .misttyClosePane
    case .closeTab:             return .misttyCloseTab
    case .closeWindow:          return .misttyCloseWindow
    case .windowMode:           return .misttyWindowMode
    case .copyMode:             return .misttyCopyMode
    case .yankHints:            return .misttyYankHints
    case .sessionManager:       return .misttySessionManager
    case .toggleSidebar:        return .misttyToggleSidebar
    case .toggleTabBar:         return .misttyToggleTabBar
    case .reloadConfig:         return .misttyReloadConfig
    case .splitHorizontal:      return .misttySplitHorizontal
    case .splitHorizontalPlain: return .misttySplitHorizontalPlain
    case .splitVertical:        return .misttySplitVertical
    case .splitVerticalPlain:   return .misttySplitVerticalPlain
    case .reopenClosedWindow:   return .misttyReopenClosedWindow
    case .renameTab:            return .misttyRenameTab
    case .renameSession:        return .misttyRenameSession
    case .nextTab:              return .misttyNextTab
    case .prevTab:              return .misttyPrevTab
    case .nextSession:          return .misttyNextSession
    case .prevSession:          return .misttyPrevSession
    // The "swap session" actions reuse the existing move-session
    // notifications: moving a session up *is* swapping with its
    // prior neighbour. Keeps the diff small.
    case .swapSessionDown:      return .misttyMoveSessionDown
    case .swapSessionUp:        return .misttyMoveSessionUp
    }
  }
}
```

Add the two new notification names to `Mistty/App/MisttyApp.swift`'s `Notification.Name` extension (existing block at the bottom). Append next to the others:

```swift
static let misttyCloseWindow = Notification.Name("misttyCloseWindow")
static let misttyToggleSidebar = Notification.Name("misttyToggleSidebar")
```

(`misttyToggleSidebar` is added because today the menu Button modifies `@AppStorage("sidebarVisible")` directly — when the monitor takes over, the monitor will post a notification that the WindowRootView observes. Wired in Task 7.)

- [ ] **Step 4: Run, expect pass**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ShortcutActionTests 2>&1 | tee /tmp/mistty-test-task3.log | tail -20`
Expected: PASS for all 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Config/ShortcutAction.swift Mistty/App/MisttyApp.swift \
        MisttyTests/Config/ShortcutActionTests.swift
git commit -m "feat: ShortcutAction enum + defaults + per-action FirePolicy

25 typed actions (TOML rawvalues stable across code renames), default
chords baked in, FirePolicy encodes the close-action / window-mode /
modal-disable guards as data instead of inline conditions in monitors."
```

---

## Task 4: ShortcutsConfig — parse TOML, layered defaults, conflict detection

**Files:**
- Create: `Mistty/Config/ShortcutsConfig.swift`
- Test: `MisttyTests/Config/ShortcutsConfigTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// MisttyTests/Config/ShortcutsConfigTests.swift
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
    // Other actions untouched.
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
    // Old default no longer maps to new_tab (it maps to nothing).
    #expect(cfg.action(matching: Chord("cmd+t")!) == nil)
  }
}

private func parse(_ toml: String) throws -> ShortcutsConfig {
  let table = try TOMLTable(string: toml)
  return try ShortcutsConfig.parse(table["shortcuts"]?.table ?? TOMLTable())
}
```

- [ ] **Step 2: Run, expect fail**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ShortcutsConfigTests 2>&1 | tee /tmp/mistty-test-task4.log | tail -25`
Expected: FAIL — `ShortcutsConfig` undefined.

- [ ] **Step 3: Implement**

```swift
// Mistty/Config/ShortcutsConfig.swift
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
    var actions: [ShortcutAction]
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

    if tabMod == sessionMod {
      throw ShortcutConfigError.indexedModifierClash(tabMod)
    }

    // Conflict detection: build reverse index, collect collisions.
    var reverse: [Chord: [ShortcutAction]] = [:]
    // Sort actions for deterministic conflict ordering.
    let sortedActions = bindings.keys.sorted { $0.rawValue < $1.rawValue }
    for action in sortedActions {
      for chord in bindings[action]! {
        reverse[chord, default: []].append(action)
      }
    }
    let conflicts = reverse
      .filter { $1.count > 1 }
      .map { ShortcutConfigError.Conflict(chord: $0.key, actions: $0.value) }
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
        if s.isEmpty { continue } // mid-array empty strings are silently ignored
        guard let chord = Chord(s) else {
          throw ShortcutConfigError.unparseableChord(action: action.rawValue, raw: s)
        }
        if !out.contains(chord) { out.append(chord) } // dedupe
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
```

- [ ] **Step 4: Run, expect pass**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ShortcutsConfigTests 2>&1 | tee /tmp/mistty-test-task4.log | tail -25`
Expected: PASS for all 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Config/ShortcutsConfig.swift MisttyTests/Config/ShortcutsConfigTests.swift
git commit -m "feat: ShortcutsConfig — parse [shortcuts] with conflict detection

Layered over ShortcutAction.defaults. String-or-array values, empty
string disables a default, conflict detection collects every chord
collision into ShortcutConfigError.conflicts so users can fix a whole
batch in one save instead of whack-a-moling one per reload."
```

---

## Task 5: Wire ShortcutsConfig into MisttyConfig (parse + save)

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift`
- Modify: `MisttyTests/Config/MisttyConfigTests.swift`

- [ ] **Step 1: Add tests for parse + save round-trip**

Append to `MisttyTests/Config/MisttyConfigTests.swift`:

```swift
// Inside the existing `MisttyConfigTests` struct.
extension MisttyConfigTests {
  @Test func shortcutsTableParses() throws {
    let cfg = try MisttyConfig.parse("""
    [shortcuts]
    new_tab = "cmd+shift+n"
    """)
    #expect(cfg.shortcuts.chords(for: .newTab) == [Chord("cmd+shift+n")!])
  }

  @Test func shortcutsRoundTripOmitsDefaults() throws {
    var cfg = MisttyConfig()
    // Mutate one shortcut.
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
    #expect(!written.contains(#"close_pane ="#))
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
```

- [ ] **Step 2: Run, expect fail**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/MisttyConfigTests 2>&1 | tee /tmp/mistty-test-task5.log | tail -25`
Expected: FAIL — `MisttyConfig.shortcuts` undefined.

- [ ] **Step 3: Add `shortcuts` to `MisttyConfig`**

Modify `Mistty/Config/MisttyConfig.swift`:

```swift
// Add to MisttyConfig struct, near `var ui: UIConfig = UIConfig()`:
var shortcuts: ShortcutsConfig = .default
```

In `MisttyConfig.parse(_:)`, after the `[ui]` block (~line 308 in current file), add:

```swift
if let shortcutsTable = table["shortcuts"]?.table {
  config.shortcuts = try ShortcutsConfig.parse(shortcutsTable)
}
```

In `MisttyConfig.save(to:)`, after the `[ui]` block, add:

```swift
// Emit only entries that differ from the default.
let defaults = ShortcutAction.defaults
let userBindings = shortcuts.bindings
var shortcutLines: [String] = []
for action in ShortcutAction.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
  let resolved = userBindings[action] ?? []
  let defaultChords = defaults[action] ?? []
  guard resolved != defaultChords else { continue }
  if resolved.isEmpty {
    shortcutLines.append("\(action.rawValue) = \"\"")
  } else if resolved.count == 1 {
    shortcutLines.append("\(action.rawValue) = \"\(resolved[0].toString())\"")
  } else {
    let arr = resolved.map { #""\#($0.toString())""# }.joined(separator: ", ")
    shortcutLines.append("\(action.rawValue) = [\(arr)]")
  }
}
if shortcuts.tabIndexModifier != .command {
  shortcutLines.append("focus_tab_modifier = \"\(modifierString(shortcuts.tabIndexModifier))\"")
}
if shortcuts.sessionIndexModifier != .control {
  shortcutLines.append(
    "focus_session_modifier = \"\(modifierString(shortcuts.sessionIndexModifier))\"")
}
if !shortcutLines.isEmpty {
  lines.append("")
  lines.append("[shortcuts]")
  lines.append(contentsOf: shortcutLines)
}
```

Add helpers to `MisttyConfig`:

```swift
private func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
  var parts: [String] = []
  if flags.contains(.command) { parts.append("cmd") }
  if flags.contains(.shift)   { parts.append("shift") }
  if flags.contains(.option)  { parts.append("opt") }
  if flags.contains(.control) { parts.append("ctrl") }
  return parts.joined(separator: "+")
}
```

Add a `Chord.toString()` extension to `Mistty/Config/Chord.swift`:

```swift
extension Chord {
  /// Round-trip back to TOML. Modifier order is canonicalized to
  /// cmd → shift → opt → ctrl so saves are deterministic.
  func toString() -> String {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("cmd") }
    if modifiers.contains(.shift)   { parts.append("shift") }
    if modifiers.contains(.option)  { parts.append("opt") }
    if modifiers.contains(.control) { parts.append("ctrl") }
    switch key {
    case .character(let c): parts.append(String(c))
    case .special(let s):   parts.append(s.rawValue)
    }
    return parts.joined(separator: "+")
  }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/MisttyConfigTests 2>&1 | tee /tmp/mistty-test-task5.log | tail -25`
Expected: PASS — including the new tests + all pre-existing config tests still green.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift Mistty/Config/Chord.swift \
        MisttyTests/Config/MisttyConfigTests.swift
git commit -m "feat: parse [shortcuts] in MisttyConfig + save round-trip

[shortcuts] entries that match the default are omitted from save() so
clean configs don't grow noise. Chord.toString() canonicalizes
modifier order for deterministic round-trips."
```

---

## Task 6: PopupDefinition — adopt Chord parser

**Files:**
- Modify: `Mistty/Models/PopupDefinition.swift`
- Modify: `Mistty/Config/MisttyConfig.swift`
- Modify: `Mistty/Views/Settings/SettingsView.swift`
- Modify: `Mistty/App/MisttyApp.swift` (delete inline `parseShortcutKey` / `parseShortcutModifiers`)

- [ ] **Step 1: Add a regression test to confirm popup chord parses through `Chord`**

Append to `MisttyTests/Config/MisttyConfigTests.swift`:

```swift
extension MisttyConfigTests {
  @Test func popupChordParsesViaChord() throws {
    let cfg = try MisttyConfig.parse("""
    [[popup]]
    name = "scratch"
    command = "vim"
    shortcut = "cmd+shift+x"
    """)
    let popup = cfg.popups.first
    #expect(popup?.shortcutChord == Chord("cmd+shift+x"))
    #expect(popup?.shortcutRaw == "cmd+shift+x")
  }
}
```

- [ ] **Step 2: Run, expect fail**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/MisttyConfigTests 2>&1 | tee /tmp/mistty-test-task6.log | tail -20`
Expected: FAIL — `popup.shortcutChord` / `popup.shortcutRaw` not defined.

- [ ] **Step 3: Reshape `PopupDefinition`**

Replace the body of `Mistty/Models/PopupDefinition.swift`:

```swift
import Foundation

enum PopupCwdSource: String, Codable, Sendable, Equatable, CaseIterable {
  case session
  case activePane = "active_pane"
  case home

  var displayName: String {
    switch self {
    case .session: return "Session"
    case .activePane: return "Active pane"
    case .home: return "Home (~)"
    }
  }
}

struct PopupDefinition: Codable, Sendable, Equatable {
  var name: String
  var command: String
  /// Raw user-typed shortcut string (e.g. "cmd+shift+x" or empty/nil).
  /// Preserved verbatim for round-trip via `MisttyConfig.save()` and the
  /// Settings text-field binding. Parse failures here are non-fatal: the
  /// popup keeps its raw text but `shortcutChord` is nil so it just won't
  /// bind a chord.
  var shortcutRaw: String?
  var width: Double
  var height: Double
  var closeOnExit: Bool
  var cwdSource: PopupCwdSource
  var shellWrap: Bool

  /// Parsed chord, or nil if `shortcutRaw` is empty / unparseable.
  var shortcutChord: Chord? {
    guard let raw = shortcutRaw, !raw.isEmpty else { return nil }
    return Chord(raw)
  }

  init(
    name: String,
    command: String,
    shortcut: String? = nil,
    width: Double = 0.8,
    height: Double = 0.8,
    closeOnExit: Bool = true,
    cwdSource: PopupCwdSource = .activePane,
    shellWrap: Bool = true
  ) {
    self.name = name
    self.command = command
    self.shortcutRaw = shortcut
    self.width = width
    self.height = height
    self.closeOnExit = closeOnExit
    self.cwdSource = cwdSource
    self.shellWrap = shellWrap
  }
}

// Codable migration: existing on-disk JSON snapshots key `shortcut` as a
// String?. Map it onto `shortcutRaw` on decode.
extension PopupDefinition {
  enum CodingKeys: String, CodingKey {
    case name, command, width, height, closeOnExit, cwdSource, shellWrap
    case shortcut       // legacy + canonical key on disk
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    command = try c.decode(String.self, forKey: .command)
    shortcutRaw = try c.decodeIfPresent(String.self, forKey: .shortcut)
    width = try c.decode(Double.self, forKey: .width)
    height = try c.decode(Double.self, forKey: .height)
    closeOnExit = try c.decode(Bool.self, forKey: .closeOnExit)
    cwdSource = try c.decode(PopupCwdSource.self, forKey: .cwdSource)
    shellWrap = try c.decode(Bool.self, forKey: .shellWrap)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(command, forKey: .command)
    try c.encodeIfPresent(shortcutRaw, forKey: .shortcut)
    try c.encode(width, forKey: .width)
    try c.encode(height, forKey: .height)
    try c.encode(closeOnExit, forKey: .closeOnExit)
    try c.encode(cwdSource, forKey: .cwdSource)
    try c.encode(shellWrap, forKey: .shellWrap)
  }
}
```

- [ ] **Step 4: Update `MisttyConfig.swift` to read/write `shortcutRaw`**

In `MisttyConfig.parse(_:)`, find the popup-parsing block (around line 245):

Old:
```swift
shortcut: t["shortcut"]?.string,
```

New:
```swift
shortcut: t["shortcut"]?.string,  // PopupDefinition.init still maps to shortcutRaw
```

(No change required since the init parameter is still named `shortcut`.) In the `save()` block (around line 471):

Old:
```swift
if let shortcut = popup.shortcut {
  lines.append("shortcut = \"\(shortcut)\"")
}
```

New:
```swift
if let raw = popup.shortcutRaw, !raw.isEmpty {
  lines.append("shortcut = \"\(tomlEscape(raw))\"")
}
```

- [ ] **Step 5: Update `MisttyApp.swift` to use `Chord` for popup menu binding**

In `Mistty/App/MisttyApp.swift`, replace the popup ForEach block (around lines 267-280):

Old:
```swift
ForEach(Array(config.popups.enumerated()), id: \.offset) { _, popup in
  if let key = parseShortcutKey(popup.shortcut),
    let modifiers = parseShortcutModifiers(popup.shortcut)
  {
    Button("Toggle \(popup.name)") {
      NotificationCenter.default.post(
        name: .misttyPopupToggle,
        object: nil,
        userInfo: ["name": popup.name]
      )
    }
    .keyboardShortcut(key, modifiers: modifiers)
  }
}
```

New:
```swift
ForEach(Array(config.popups.enumerated()), id: \.offset) { _, popup in
  if let chord = popup.shortcutChord {
    let (key, mods) = chord.swiftUI()
    Button("Toggle \(popup.name)") {
      NotificationCenter.default.post(
        name: .misttyPopupToggle,
        object: nil,
        userInfo: ["name": popup.name]
      )
    }
    .keyboardShortcut(key, modifiers: mods)
  }
}
```

Delete the `shortcutParts`, `parseShortcutKey`, `parseShortcutModifiers` helpers (lines ~327-354).

- [ ] **Step 6: Update `SettingsView.swift` popup shortcut binding**

In `Mistty/Views/Settings/SettingsView.swift`, around line 80, change `popup.shortcut` references to `popup.shortcutRaw`:

```swift
get: { config.popups[index].shortcutRaw ?? "" },
set: { config.popups[index].shortcutRaw = $0.isEmpty ? nil : $0 }
```

- [ ] **Step 7: Run tests, expect pass**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/MisttyConfigTests 2>&1 | tee /tmp/mistty-test-task6.log | tail -20`

Also build the app to catch SettingsView / MisttyApp callsites:

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' build 2>&1 | tee /tmp/mistty-build-task6.log | tail -20`
Expected: build succeeds, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Mistty/Models/PopupDefinition.swift Mistty/Config/MisttyConfig.swift \
        Mistty/App/MisttyApp.swift Mistty/Views/Settings/SettingsView.swift \
        MisttyTests/Config/MisttyConfigTests.swift
git commit -m "refactor: popup shortcuts use Chord parser

PopupDefinition now stores both the raw user string (for Settings UI
round-trip) and exposes shortcutChord computed via the Chord parser.
The bespoke parseShortcutKey/parseShortcutModifiers helpers in
MisttyApp are deleted in favour of Chord(_:)."
```

---

## Task 7: ShortcutMonitor — single config-driven event monitor

**Files:**
- Create: `Mistty/Services/ShortcutMonitor.swift`
- Test: `MisttyTests/Services/ShortcutMonitorTests.swift`

This is the largest task. The monitor doesn't run inside an `NSEvent` loop in tests — we test the pure handler.

- [ ] **Step 1: Write failing tests for the pure handler**

```swift
// MisttyTests/Services/ShortcutMonitorTests.swift
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
}
```

- [ ] **Step 2: Run, expect fail**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ShortcutMonitorTests 2>&1 | tee /tmp/mistty-test-task7.log | tail -25`
Expected: FAIL — `ShortcutMonitor` undefined.

- [ ] **Step 3: Implement the monitor**

```swift
// Mistty/Services/ShortcutMonitor.swift
import AppKit
import Foundation

/// Pure handler + an NSEvent monitor lifecycle wrapper. The handler is
/// extracted onto its own type so unit tests can drive it without a real
/// event loop.
final class ShortcutMonitor {
  /// Caller-supplied window/state queries. Live values change as the user
  /// moves around; recomputed on every keyDown rather than cached.
  struct Context {
    var isTerminalWindowKey: () -> Bool
    var firstResponderIsTextField: () -> Bool
    var inModalMode: () -> Bool
  }

  enum IndexedAction: Equatable {
    case focusTab(index: Int)
    case focusSession(index: Int)
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

    // Indexed-action match: digit 1..9 with the configured modifier.
    let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    let flags = event.modifierFlags.intersection(mask)
    if flags == config.tabIndexModifier || flags == config.sessionIndexModifier {
      if let chars = event.charactersIgnoringModifiers,
         chars.count == 1, let digit = Int(chars), (1...9).contains(digit)
      {
        let action: IndexedAction =
          flags == config.tabIndexModifier
          ? .focusTab(index: digit)
          : .focusSession(index: digit)
        return HandleResult(consumed: true, action: nil, indexedAction: action)
      }
    }

    // Build a Chord for the incoming event.
    let chord = Chord(event: event)
    guard let chord else {
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
    // Special key by keyCode first.
    if let s = Special.allCases.first(where: { $0.keyCode == event.keyCode }) {
      self.init(key: .special(s), modifiers: mods)
      return
    }
    // Character path.
    guard let chars = event.charactersIgnoringModifiers?.lowercased(),
          chars.count == 1, let c = chars.first
    else { return nil }
    self.init(key: .character(c), modifiers: mods)
  }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test -only-testing:MisttyTests/ShortcutMonitorTests 2>&1 | tee /tmp/mistty-test-task7.log | tail -25`
Expected: PASS for all 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Services/ShortcutMonitor.swift MisttyTests/Services/ShortcutMonitorTests.swift
git commit -m "feat: ShortcutMonitor — single config-driven NSEvent local monitor

handle(event:) is pure so tests drive it without a real event loop;
install() wraps it in NSEvent.addLocalMonitorForEvents and posts the
action's notification (or the indexed focus-tab/focus-session
notification with userInfo['index'])."
```

---

## Task 8: Wire ShortcutMonitor into ContentView, delete old monitors

**Files:**
- Modify: `Mistty/App/ContentView.swift`

This is the cutover task. Three monitors are deleted; one is added. The session-manager `eventMonitor`, `windowModeMonitor`, `copyModeMonitor`, and `ctrlNavMonitor` stay — those handle in-mode keys, which are out of scope.

- [ ] **Step 1: Add a `shortcutMonitor` `@State` and remove the old three**

In `Mistty/App/ContentView.swift`, replace the monitor `@State` declarations near line 16-22:

Old:
```swift
@State private var windowModeMonitor: Any?
@State private var copyModeMonitor: Any?
@State private var ctrlNavMonitor: Any?
@State private var closeMonitor: Any?
@State private var altShortcutMonitor: Any?
@State private var windowModeShortcutMonitor: Any?
```

New:
```swift
@State private var windowModeMonitor: Any?
@State private var copyModeMonitor: Any?
@State private var ctrlNavMonitor: Any?
@State private var shortcutMonitor: ShortcutMonitor?
```

- [ ] **Step 2: Replace monitor install/remove sites in `.onAppear`/`.onDisappear`**

Around line 333-345 (the `if … == nil` install block), replace:

Old:
```swift
if ctrlNavMonitor == nil {
  installCtrlNavMonitor()
}
if closeMonitor == nil {
  installCloseMonitor()
}
if altShortcutMonitor == nil {
  installAltShortcutMonitor()
}
if windowModeShortcutMonitor == nil {
  installWindowModeShortcutMonitor()
}
```

New:
```swift
if ctrlNavMonitor == nil {
  installCtrlNavMonitor()
}
if shortcutMonitor == nil {
  installShortcutMonitor()
}
```

In the matching `.onDisappear` block, replace the three teardown calls with one:

Old:
```swift
removeCtrlNavMonitor()
removeCloseMonitor()
removeAltShortcutMonitor()
removeWindowModeShortcutMonitor()
```

New:
```swift
removeCtrlNavMonitor()
removeShortcutMonitor()
```

(Find the exact lines via `grep -n "removeCloseMonitor\|removeAltShortcutMonitor\|removeWindowModeShortcutMonitor" Mistty/App/ContentView.swift`. There's typically one `.onDisappear` and one teardown helper that handles `escape` from the view. Be sure to update both.)

- [ ] **Step 3: Add `installShortcutMonitor` / `removeShortcutMonitor` helpers**

Append to `ContentView` (near where the deleted helpers used to live, around line 1294):

```swift
private func installShortcutMonitor() {
  let context = ShortcutMonitor.Context(
    isTerminalWindowKey: { [windowsStore] in
      windowsStore.isActiveTerminalWindow(state: state)
        && windowsStore.isTerminalWindowKey()
    },
    firstResponderIsTextField: {
      NSApp.keyWindow?.firstResponder is NSText
    },
    inModalMode: { [state, showingSessionManager] in
      let activeTab = state.activeSession?.activeTab
      return showingSessionManager
        || activeTab?.isWindowModeActive == true
        || activeTab?.isCopyModeActive == true
    }
  )
  let monitor = ShortcutMonitor(config: MisttyConfig.current.shortcuts, context: context)
  monitor.install()
  shortcutMonitor = monitor
}

private func removeShortcutMonitor() {
  shortcutMonitor?.uninstall()
  shortcutMonitor = nil
}
```

Add a `.onReceive` so the monitor's snapshot rebuilds on config reload. In the `.onAppear` block (or near the existing `.onReceive(NotificationCenter.default.publisher(for: .misttyConfigDidReload))` call in `ContentView`):

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyConfigDidReload)) { _ in
  shortcutMonitor?.updateConfig(MisttyConfig.current.shortcuts)
}
```

If a `.misttyConfigDidReload` handler already exists in this view, append to it instead of duplicating.

- [ ] **Step 4: Delete the obsolete helpers**

Delete from `ContentView.swift`:
- `installAltShortcutMonitor()` and `removeAltShortcutMonitor()` (around lines 1238-1292)
- `installCloseMonitor()` and `removeCloseMonitor()` (around lines 1309-1327)
- `installWindowModeShortcutMonitor()` and `removeWindowModeShortcutMonitor()` (around lines 1336-1360)

Plus the comment block above `installAltShortcutMonitor` that documents the alt-shortcut workaround (around lines 1216-1222).

- [ ] **Step 5: Build and run the existing test suite**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test 2>&1 | tee /tmp/mistty-test-task8.log | tail -40`
Expected: build succeeds, all tests pass (no test regressions; `ShortcutMonitor` already covered by Task 7).

- [ ] **Step 6: Manual smoke test**

```bash
just run
```

Verify:
- `cmd+t` opens a new tab.
- `cmd+w` closes a pane.
- `cmd+ctrl+w` closes a tab (was `cmd+shift+w`).
- `cmd+shift+w` closes the *window* (new — the focused terminal window).
- `cmd+]` / `cmd+[` switch tabs.
- `cmd+up` / `cmd+down` switch tabs (alias).
- `cmd+opt+up` / `cmd+opt+down` cycle sessions.
- `cmd+shift+up` / `cmd+shift+down` swap sessions up/down.
- `cmd+shift+]` / `cmd+shift+[` cycle sessions (bracket alias).
- `cmd+opt+]` / `cmd+opt+[` swap sessions (bracket alias).
- `cmd+1`..`cmd+9` focus tab.
- `ctrl+1`..`ctrl+9` focus session.
- `cmd+x` toggles window mode; in window mode, hjkl/arrows still work (those are `windowModeMonitor`, untouched).
- `cmd+x` while focused on a TextField (sidebar rename) cuts text.
- `cmd+w` while Settings is key closes Settings.

- [ ] **Step 7: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "feat: cutover to ShortcutMonitor; delete three legacy NSEvent monitors

closeMonitor, altShortcutMonitor, and windowModeShortcutMonitor all
collapse into a single config-driven ShortcutMonitor. The three
behavior changes from PLAN.md (close-tab → cmd+ctrl+w, close-window →
cmd+shift+w, session-cycle/swap arrow swap) take effect by virtue of
the new defaults in ShortcutAction. windowModeMonitor / copyModeMonitor
/ ctrlNavMonitor / session-manager eventMonitor stay — those handle
in-mode keys, which are out of scope for this work."
```

---

## Task 9: Wire menu shortcuts to the registry + add Close Window menu item

**Files:**
- Modify: `Mistty/App/MisttyApp.swift`
- Modify: `Mistty/App/WindowRootView.swift`

- [ ] **Step 1: Add a `kbShortcut` helper on the `MisttyApp` body**

In `Mistty/App/MisttyApp.swift`, near the helpers at the bottom of the struct (after `applyTitleBarStyleToWindows`):

```swift
@ViewBuilder
private func kbShortcut<V: View>(
  _ action: ShortcutAction, on view: V
) -> some View {
  if let chord = config.shortcuts.primary(for: action) {
    let (key, mods) = chord.swiftUI()
    view.keyboardShortcut(key, modifiers: mods)
  } else {
    view
  }
}
```

- [ ] **Step 2: Replace inline `.keyboardShortcut(...)` literals with the helper**

For each menu Button in the `.commands { CommandGroup(after: .toolbar) { … } }` block (lines ~92-281), replace the literal modifier with a `kbShortcut` call. Example for "Toggle Sidebar" (lines 96-101):

Old:
```swift
Button("Toggle Sidebar") {
  withAnimation(.easeInOut(duration: 0.18)) {
    sidebarVisible.toggle()
  }
}
.keyboardShortcut("s", modifiers: .command)
```

New:
```swift
kbShortcut(
  .toggleSidebar,
  on: Button("Toggle Sidebar") {
    withAnimation(.easeInOut(duration: 0.18)) {
      sidebarVisible.toggle()
    }
  }
)
```

Apply this transformation to each Button in the CommandGroup. Mapping table:

| Button | Action |
|---|---|
| Toggle Sidebar | `.toggleSidebar` |
| Toggle Tab Bar | `.toggleTabBar` |
| Reload Config | `.reloadConfig` |
| New Tab | `.newTab` |
| New Tab (Plain) | `.newTabPlain` |
| Split Pane Horizontally | `.splitHorizontal` |
| Split Pane Horizontally (Plain) | `.splitHorizontalPlain` |
| Split Pane Vertically | `.splitVertical` |
| Split Pane Vertically (Plain) | `.splitVerticalPlain` |
| Session Manager | `.sessionManager` |
| Close Pane | `.closePane` |
| Close Tab | `.closeTab` |
| Reopen Closed Window | `.reopenClosedWindow` |
| Window Mode | `.windowMode` |
| Copy Mode | `.copyMode` |
| Yank Hints | `.yankHints` |
| Rename Tab | `.renameTab` |
| Rename Session | `.renameSession` |
| Next Tab | `.nextTab` |
| Previous Tab | `.prevTab` |
| Previous Session | `.prevSession` |
| Next Session | `.nextSession` |
| Move Session Up | `.swapSessionUp` |
| Move Session Down | `.swapSessionDown` |

For the `Focus Tab \(index)` ForEach (lines 213-222), replace the modifier with `config.shortcuts.tabIndexModifier`-derived `EventModifiers`:

Old:
```swift
ForEach(1...9, id: \.self) { index in
  Button("Focus Tab \(index)") {
    NotificationCenter.default.post(
      name: .misttyFocusTabByIndex, object: nil, userInfo: ["index": index - 1])
  }
  .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
}
```

New:
```swift
ForEach(1...9, id: \.self) { index in
  Button("Focus Tab \(index)") {
    NotificationCenter.default.post(
      name: .misttyFocusTabByIndex, object: nil, userInfo: ["index": index - 1])
  }
  .keyboardShortcut(
    KeyEquivalent(Character("\(index)")),
    modifiers: eventModifiers(from: config.shortcuts.tabIndexModifier))
}
```

Same for the Focus Session loop (use `sessionIndexModifier`).

Add a small helper to `MisttyApp`:

```swift
private func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
  var m: EventModifiers = []
  if flags.contains(.command) { m.insert(.command) }
  if flags.contains(.shift)   { m.insert(.shift) }
  if flags.contains(.option)  { m.insert(.option) }
  if flags.contains(.control) { m.insert(.control) }
  return m
}
```

- [ ] **Step 3: Add the `Close Window` menu item**

After the existing "Close Tab" Button (around line 177), add:

```swift
kbShortcut(
  .closeWindow,
  on: Button("Close Window") {
    if windowsStore.isTerminalWindowKey() {
      DebugLog.shared.log("cmdw", "menu Close Window → posting notification")
      NotificationCenter.default.post(name: .misttyCloseWindow, object: nil)
    } else {
      NSApp.keyWindow?.performClose(nil)
    }
  }
)
```

- [ ] **Step 4: Handle `.misttyCloseWindow` in `WindowRootView`**

In `Mistty/App/WindowRootView.swift`, find the existing `.onReceive` chain (around line 64-89 of `MisttyApp.swift`'s `WindowRootView` body — actually located in `WindowRootView.swift`). Add another `.onReceive`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyCloseWindow)) { _ in
  // Only the focused terminal window should respond.
  guard windowsStore.isTerminalWindowKey() else { return }
  NSApp.keyWindow?.performClose(nil)
}
```

If `WindowRootView` doesn't have a direct reference to `windowsStore`, plumb it through (it almost certainly does — it's the per-window root).

- [ ] **Step 5: Add `Toggle Sidebar` notification wiring**

`Toggle Sidebar` was the only menu Button whose action lived inline in the menu closure (mutating `@AppStorage`). The monitor now routes through `.misttyToggleSidebar`. Add an `.onReceive` to `WindowRootView`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyToggleSidebar)) { _ in
  withAnimation(.easeInOut(duration: 0.18)) {
    sidebarVisible.toggle()
  }
}
```

(Adapt the AppStorage access pattern to whatever WindowRootView already uses; same `@AppStorage("sidebarVisible")` declaration.)

The menu Button can keep its inline closure too — it fires only on mouse click; both paths converge on the same store toggle. Or simplify by posting the notification from the Button:

```swift
kbShortcut(
  .toggleSidebar,
  on: Button("Toggle Sidebar") {
    NotificationCenter.default.post(name: .misttyToggleSidebar, object: nil)
  }
)
```

- [ ] **Step 6: Build, run tests**

Run: `xcodebuild -scheme Mistty -destination 'platform=macOS' test 2>&1 | tee /tmp/mistty-test-task9.log | tail -30`
Expected: build succeeds, all tests pass.

- [ ] **Step 7: Manual smoke test**

```bash
just run
```

Verify the menu hints display the new chords:
- View → Close Tab shows `⌘^W`.
- View → Close Window shows `⌘⇧W`.
- View → Move Session Up shows `⌘⇧↑`.
- Each menu item still works on mouse click.
- Editing `~/.config/mistty/config.toml` to add `[shortcuts]\nnew_tab = "cmd+shift+n"` then triggering View → Reload Config updates the menu hint live (may take a SwiftUI rebuild tick).

- [ ] **Step 8: Commit**

```bash
git add Mistty/App/MisttyApp.swift Mistty/App/WindowRootView.swift
git commit -m "feat: menu shortcuts read from ShortcutsConfig + add Close Window item

Each .keyboardShortcut(...) call routes through ShortcutAction.primary,
the indexed focus-tab/focus-session loops use the configurable index
modifiers, and a new Close Window menu item handles cmd+shift+w (the
PLAN.md addition). Toggle Sidebar moves to a notification round-trip
so the keyboard and mouse-click paths share one toggle site."
```

---

## Task 10: Document the new schema and migration in the example config

**Files:**
- Modify: `docs/config-example.toml`

- [ ] **Step 1: Append a `[shortcuts]` block to the example config**

Append to `docs/config-example.toml`:

```toml
# ---------------------------------------------------------------------------
# Keyboard shortcuts
# ---------------------------------------------------------------------------
# Override any of Mistty's global / menu-bar shortcuts by setting the action
# under [shortcuts] to a chord string or array of chord strings.
#
# Chord grammar:
#   <modifier>+<modifier>+...+<key>
#   Modifiers: cmd, shift, opt (alias: alt), ctrl. Order doesn't matter.
#   Keys: any single character (a, ], 1, /), or a special-key word:
#         up, down, left, right, escape, return, tab, space, backspace,
#         home, end, pageup, pagedown, f1..f12.
#   Separator: + or - (both accepted).
#
# Set a binding to "" to disable the default. Set to an array to bind multiple
# chords to the same action.
#
# The bracket-based and arrow-based aliases for tab/session navigation are
# DELIBERATELY DIFFERENT modifiers from each other:
#   - cmd+opt+arrows         cycles sessions (Arc/Zen-style)
#   - cmd+shift+arrows       swaps sessions
#   - cmd+shift+brackets     cycles sessions (legacy bracket binding)
#   - cmd+opt+brackets       swaps sessions
# i.e. cmd+shift+down (swap) and cmd+shift+] (cycle) are the same modifier
# but different actions. Same for cmd+opt+down (cycle) and cmd+opt+] (swap).
# This is intentional — preserves muscle memory for both arrow and bracket
# users. Override below if you want to unify them.
#
# Conflicts (two actions bound to the same chord) abort config reload with an
# error in Settings. The config falls back to the last good snapshot.

#[shortcuts]
# new_tab                = "cmd+t"
# new_tab_plain          = "cmd+opt+t"
# close_pane             = "cmd+w"
# close_tab              = "cmd+ctrl+w"     # PLAN.md: was cmd+shift+w
# close_window           = "cmd+shift+w"    # PLAN.md: new action
# window_mode            = "cmd+x"
# copy_mode              = "cmd+shift+c"
# yank_hints             = "cmd+shift+y"
# session_manager        = "cmd+j"
# toggle_sidebar         = "cmd+s"
# toggle_tab_bar         = "cmd+shift+b"
# reload_config          = ""               # no default chord
# split_horizontal       = "cmd+d"
# split_horizontal_plain = "cmd+opt+d"
# split_vertical         = "cmd+shift+d"
# split_vertical_plain   = "cmd+shift+opt+d"
# reopen_closed_window   = "cmd+shift+t"
# rename_tab             = "cmd+shift+r"
# rename_session         = "cmd+opt+r"
# next_tab               = ["cmd+]", "cmd+down"]
# prev_tab               = ["cmd+[", "cmd+up"]
# next_session           = ["cmd+opt+down", "cmd+shift+]"]
# prev_session           = ["cmd+opt+up", "cmd+shift+["]
# swap_session_down      = ["cmd+shift+down", "cmd+opt+]"]
# swap_session_up        = ["cmd+shift+up", "cmd+opt+["]
#
# Indexed shortcuts: cmd+1..cmd+9 focus tabs, ctrl+1..ctrl+9 focus sessions.
# Override the modifier; remap individual digits is not supported.
# focus_tab_modifier     = "cmd"
# focus_session_modifier = "ctrl"
```

- [ ] **Step 2: Commit**

```bash
git add docs/config-example.toml
git commit -m "docs: document [shortcuts] block in config-example.toml

Includes the chord grammar, the bracket/arrow modifier inconsistency
callout, and every action's default value as a copy-pasteable comment."
```

---

## Task 11: End-to-end manual verification + release-note draft

**Files:**
- Modify: `PLAN.md` (move "Keyboard shortcut configuration" from TODO to Implemented).

- [ ] **Step 1: Manual end-to-end checklist**

Build once with `just run` and walk through:

- [ ] `cmd+t` opens a new tab.
- [ ] `cmd+w` closes the focused pane.
- [ ] `cmd+ctrl+w` closes the focused tab (was `cmd+shift+w`).
- [ ] `cmd+shift+w` closes the focused terminal window.
- [ ] `cmd+shift+w` while a non-terminal window (Settings) is key uses the system close (Settings closes).
- [ ] `cmd+]` / `cmd+[` cycle tabs.
- [ ] `cmd+up` / `cmd+down` cycle tabs (alias).
- [ ] `cmd+opt+up` / `cmd+opt+down` cycle sessions.
- [ ] `cmd+shift+up` / `cmd+shift+down` swap sessions.
- [ ] `cmd+shift+]` / `cmd+shift+[` cycle sessions (bracket alias).
- [ ] `cmd+opt+]` / `cmd+opt+[` swap sessions (bracket alias).
- [ ] `cmd+1`..`cmd+9` focus tab.
- [ ] `ctrl+1`..`ctrl+9` focus session.
- [ ] `cmd+x` toggles window mode; `cmd+x` while focused in sidebar rename TextField cuts text instead.
- [ ] In window mode, `hjkl` / arrows still work (windowModeMonitor untouched).
- [ ] In copy mode, vim grammar still works (copyModeMonitor untouched).
- [ ] `cmd+j` opens session manager; in session manager `cmd+]` is suppressed (modal-mode policy).
- [ ] Edit `~/.config/mistty/config.toml`, add `[shortcuts]\nnew_tab = "cmd+shift+n"`, View → Reload Config: `cmd+shift+n` opens a tab and `cmd+t` falls through to the terminal.
- [ ] Add `[shortcuts]\nnew_tab = "cmd+t"\nsession_manager = "cmd+t"`, Reload Config: red banner in Settings shows the conflict; previous chord bindings continue to work.
- [ ] `mistty-cli config reload` after the same conflict edit exits non-zero with the conflict message.

- [ ] **Step 2: Update PLAN.md**

In `PLAN.md`, remove the "Keyboard shortcut configuration" subsection from the TODO block and add a new entry under `## Implemented`:

```markdown
### Configurable keyboard shortcuts

Spec: `docs/superpowers/specs/2026-04-28-keyboard-shortcuts-config-design.md`. Plan: `docs/superpowers/plans/2026-05-01-keyboard-shortcuts-config.md`.

- All global / menu-bar shortcuts (~25 actions) now configurable via a
  `[shortcuts]` table in `~/.config/mistty/config.toml`. Layered over
  hard-coded defaults; `""` disables a default; arrays bind multiple
  chords to the same action. Live-reload via `MisttyConfig.reload()`.
- Behavior changes (Arc/Zen alignment): close-tab moved to `cmd+ctrl+w`
  (was `cmd+shift+w`), new `close_window` action on `cmd+shift+w`,
  session-cycle on `cmd+opt+arrows` (was `cmd+shift+arrows`),
  session-swap on `cmd+shift+arrows` (was `cmd+opt+arrows`). Bracket
  aliases keep their existing meaning.
- Architecture: new `Chord` value type (string parser, SwiftUI menu
  adapter, NSEvent matcher); `ShortcutAction` enum + `defaults` table +
  per-action `FirePolicy`; `ShortcutsConfig` parses + validates with
  collected conflict detection; single `ShortcutMonitor` replaces the
  three legacy NSEvent monitors (`closeMonitor`, `altShortcutMonitor`,
  `windowModeShortcutMonitor`).
- Indexed focus-tab/focus-session shortcuts collapsed into
  `focus_tab_modifier` / `focus_session_modifier` config keys (defaults
  `cmd` / `ctrl`).
- Settings UI for shortcuts deferred to the preference-pane redesign;
  in-mode keys (window-mode hjkl/etc., copy-mode vim grammar) remain
  hardcoded by design.
```

- [ ] **Step 3: Commit**

```bash
git add PLAN.md
git commit -m "docs: PLAN.md updates for configurable keyboard shortcuts

Move the "Keyboard shortcut configuration" item from TODO to Implemented."
```

---

## Self-Review

**Spec coverage check:**

| Spec section | Plan task |
|---|---|
| Goals: `[shortcuts]` table | Task 4, Task 5 |
| Goals: close-tab + close-window changes | Task 3 (defaults), Task 9 (menu item), Task 8 (cutover) |
| Goals: session arrow swap | Task 3 (defaults) |
| Goals: live-reload | Task 8 (`updateConfig` on `.misttyConfigDidReload`) |
| Non-goal: Settings UI | Confirmed not in plan |
| Non-goal: in-mode keys | Confirmed in Task 8 — windowMode/copyMode/ctrlNav monitors retained |
| Behavior changes table | Task 3 covers each row |
| `close_window` new notification | Task 3 (notification name), Task 9 (menu item + WindowRootView handler) |
| Schema (TOML) | Task 4, Task 10 |
| `Chord` type, grammar | Task 1, Task 2 |
| `ShortcutAction` registry + defaults + `FirePolicy` | Task 3 |
| Validation: conflict detection | Task 4 |
| Validation: indexed-modifier clash | Task 4 |
| `ShortcutRegistry` / `ShortcutsConfig` | Task 4 (renamed `ShortcutsConfig` to keep consistent with config-naming patterns) |
| `ShortcutMonitor` | Task 7 |
| Per-action `FirePolicy` semantics | Task 3 (defs), Task 7 (apply), Task 8 (wire context) |
| Menu binding via primary | Task 9 |
| Save round-trip omits defaults | Task 5 |
| `mistty-cli config reload` flow | Inherited from `MisttyConfig.reload()`; covered in Task 11 manual test |
| `PopupDefinition` adopt `Chord` | Task 6 |
| Migration / release notes | Task 11 |

**Placeholder scan:** No "TBD" / "implement later" / "fill in" instances; every code step shows the exact code; every test shows the exact assertions.

**Type consistency check:**
- `Chord(_:)` returns `Chord?` everywhere.
- `Chord.toString()` introduced in Task 5; referenced consistently.
- `ShortcutsConfig.chords(for:)`, `primary(for:)`, `action(matching:)` introduced in Task 4; referenced consistently in Tasks 5, 7, 9.
- `ShortcutMonitor.Context`, `HandleResult`, `IndexedAction` introduced in Task 7; referenced consistently in Task 8.
- `ShortcutAction.notificationName` introduced in Task 3; used in Task 7.
- `ShortcutAction.policy` returns `FirePolicy` (consistent across Tasks 3, 7).
- `PopupDefinition.shortcutRaw` (storage) + `shortcutChord` (computed) introduced in Task 6; referenced consistently in MisttyApp + SettingsView updates.

**Spec gap (now patched):** the spec said the `ShortcutMonitor` carries the "registry"; the plan settles on `ShortcutsConfig` directly (no separate registry type — the config *is* the lookup). Functionally equivalent and a smaller surface area; documented inline in Task 7's commit message.
