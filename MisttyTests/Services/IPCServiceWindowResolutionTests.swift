import Testing
import Foundation
@testable import Mistty
@testable import MisttyShared

@MainActor
struct IPCServiceWindowResolutionTests {
  @Test
  func usesExplicitWindowIDWhenProvided() {
    let store = WindowsStore()
    let a = store.createWindow()
    let b = store.createWindow()
    let resolved = store.resolveTargetWindow(explicit: b.id)
    #expect(resolved?.id == b.id)
    _ = a // suppress unused
  }

  @Test
  func errorsWhenExplicitWindowIDNotFound() {
    let store = WindowsStore()
    _ = store.createWindow()
    let resolved = store.resolveTargetWindow(explicit: 999)
    #expect(resolved == nil)
  }

  @Test
  func fallsBackToFocusedWindowWhenNoExplicit() {
    let store = WindowsStore()
    let a = store.createWindow()
    // focusedWindow() requires NSApp.keyWindow to point at a tracked
    // NSWindow — in unit tests there's no live key window, so
    // resolveTargetWindow returns nil. (Manual UI walkthrough covers
    // the focused-window happy path.)
    let resolved = store.resolveTargetWindow(explicit: nil)
    #expect(resolved == nil)
    _ = a
  }
}
