import Testing
import Foundation
@testable import Mistty

@MainActor
struct WindowStateTests {
  @Test
  func createSessionAppendsAndActivates() {
    let store = WindowsStore()
    let state = store.createWindow()
    let session = state.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    #expect(state.sessions.count == 1)
    #expect(state.sessions.first?.id == session.id)
    #expect(state.activeSession?.id == session.id)
  }

  @Test
  func closeSessionRemovesFromListAndUpdatesActive() {
    let store = WindowsStore()
    let state = store.createWindow()
    let a = state.createSession(name: "a", directory: URL(fileURLWithPath: "/tmp"))
    let b = state.createSession(name: "b", directory: URL(fileURLWithPath: "/tmp"))
    #expect(state.activeSession?.id == b.id)
    state.closeSession(b)
    #expect(state.sessions.count == 1)
    #expect(state.activeSession?.id == a.id)
  }

  @Test
  func sessionIDsAreGloballyUnique() {
    let store = WindowsStore()
    let a = store.createWindow()
    let b = store.createWindow()
    let s1 = a.createSession(name: "1", directory: URL(fileURLWithPath: "/"))
    let s2 = b.createSession(name: "2", directory: URL(fileURLWithPath: "/"))
    #expect(s1.id != s2.id)
  }

  @Test
  func nextPrevSessionWrapsCircular() {
    let store = WindowsStore()
    let state = store.createWindow()
    let a = state.createSession(name: "a", directory: URL(fileURLWithPath: "/"))
    let b = state.createSession(name: "b", directory: URL(fileURLWithPath: "/"))
    state.activeSession = a
    state.nextSession()
    #expect(state.activeSession?.id == b.id)
    state.nextSession()
    #expect(state.activeSession?.id == a.id)
  }

  @Test
  func nextSessionWrapsAroundWithThreeSessions() {
    let store = WindowsStore()
    let state = store.createWindow()
    _ = state.createSession(name: "a", directory: URL(fileURLWithPath: "/tmp"))
    _ = state.createSession(name: "b", directory: URL(fileURLWithPath: "/tmp"))
    let s3 = state.createSession(name: "c", directory: URL(fileURLWithPath: "/tmp"))
    #expect(state.activeSession?.id == s3.id)
    state.nextSession()
    #expect(state.activeSession?.name == "a")
  }

  @Test
  func prevSessionWrapsAroundWithThreeSessions() {
    let store = WindowsStore()
    let state = store.createWindow()
    let s1 = state.createSession(name: "a", directory: URL(fileURLWithPath: "/tmp"))
    _ = state.createSession(name: "b", directory: URL(fileURLWithPath: "/tmp"))
    _ = state.createSession(name: "c", directory: URL(fileURLWithPath: "/tmp"))
    state.activeSession = s1
    state.prevSession()
    #expect(state.activeSession?.name == "c")
  }

  @Test
  func createSessionWithExecSetsCommand() {
    let store = WindowsStore()
    let state = store.createWindow()
    let session = state.createSession(
      name: "test", directory: URL(fileURLWithPath: "/tmp"), exec: "nvim")
    #expect(session.tabs.first?.panes.first?.command == "nvim")
  }

  @Test
  func createSessionWithoutExecLeavesCommandNil() {
    let store = WindowsStore()
    let state = store.createWindow()
    let session = state.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    #expect(session.tabs.first?.panes.first?.command == nil)
  }

  @Test
  func addTabWithExecSetsCommand() {
    let store = WindowsStore()
    let state = store.createWindow()
    let session = state.createSession(name: "test", directory: URL(fileURLWithPath: "/tmp"))
    session.addTab(exec: "top")
    #expect(session.tabs.last?.panes.first?.command == "top")
  }
}
