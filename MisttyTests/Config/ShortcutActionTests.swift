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
      _ = action.notificationName
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
