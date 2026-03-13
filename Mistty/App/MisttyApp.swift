import GhosttyKit
import SwiftUI

@main
struct MisttyApp: App {
  @AppStorage("sidebarVisible") var sidebarVisible = true

  init() {
    _ = GhosttyAppManager.shared
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .commands {
      CommandGroup(after: .toolbar) {
        Divider()

        Button("Toggle Sidebar") {
          sidebarVisible.toggle()
        }
        .keyboardShortcut("s", modifiers: .command)

        Button("New Tab") {
          NotificationCenter.default.post(name: .misttyNewTab, object: nil)
        }
        .keyboardShortcut("t", modifiers: .command)

        Button("Split Pane Horizontally") {
          NotificationCenter.default.post(name: .misttySplitHorizontal, object: nil)
        }
        .keyboardShortcut("d", modifiers: .command)

        Button("Split Pane Vertically") {
          NotificationCenter.default.post(name: .misttySplitVertical, object: nil)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Button("Session Manager") {
          NotificationCenter.default.post(name: .misttySessionManager, object: nil)
        }
        .keyboardShortcut("j", modifiers: .command)

        Divider()

        Button("Close Pane") {
          NotificationCenter.default.post(name: .misttyClosePane, object: nil)
        }
        .keyboardShortcut("w", modifiers: .command)

        Button("Close Tab") {
          NotificationCenter.default.post(name: .misttyCloseTab, object: nil)
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])

        Button("Window Mode") {
          NotificationCenter.default.post(name: .misttyWindowMode, object: nil)
        }
        .keyboardShortcut("x", modifiers: .command)

        Button("Copy Mode") {
          NotificationCenter.default.post(name: .misttyCopyMode, object: nil)
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

        Divider()

        Button("Rename Tab") {
          NotificationCenter.default.post(name: .misttyRenameTab, object: nil)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }
    }

    Settings {
      SettingsView()
    }
  }
}

extension Notification.Name {
  static let misttyNewTab = Notification.Name("misttyNewTab")
  static let misttySplitHorizontal = Notification.Name("misttySplitHorizontal")
  static let misttySplitVertical = Notification.Name("misttySplitVertical")
  static let misttySessionManager = Notification.Name("misttySessionManager")
  static let misttyClosePane = Notification.Name("misttyClosePane")
  static let misttyCloseTab = Notification.Name("misttyCloseTab")
  static let misttyRenameTab = Notification.Name("misttyRenameTab")
  static let misttyWindowMode = Notification.Name("misttyWindowMode")
  static let misttyCopyMode = Notification.Name("misttyCopyMode")
}
