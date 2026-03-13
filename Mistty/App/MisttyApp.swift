import Foundation
import GhosttyKit
import SwiftUI

@main
struct MisttyApp: App {
  @State private var store = SessionStore()
  @State private var xpcListener: MisttyXPCListener?
  @AppStorage("sidebarVisible") var sidebarVisible = true

  init() {
    _ = GhosttyAppManager.shared
    installXPCServiceIfNeeded()
  }

  /// Installs the launchd plist for the CLI XPC Mach service if it doesn't already exist.
  private func installXPCServiceIfNeeded() {
    let label = "com.mistty.cli-service"
    let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents")
    let plistURL = launchAgentsDir.appendingPathComponent("\(label).plist")

    guard !FileManager.default.fileExists(atPath: plistURL.path) else { return }

    // Resolve the current app's executable path
    let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "/usr/local/bin/mistty-cli"

    let plistContent = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>MachServices</key>
          <dict>
              <key>\(label)</key>
              <true/>
          </dict>
          <key>ProgramArguments</key>
          <array>
              <string>\(executablePath)</string>
          </array>
          <key>RunAtLoad</key>
          <false/>
      </dict>
      </plist>
      """

    do {
      try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
      try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["load", plistURL.path]
      try process.run()
      process.waitUntilExit()
    } catch {
      print("Warning: failed to install XPC service plist: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
        .onAppear {
          if xpcListener == nil {
            let service = MisttyXPCService(store: store)
            let listener = MisttyXPCListener(service: service)
            listener.start()
            xpcListener = listener
          }
        }
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
