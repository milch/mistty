import SwiftUI
import GhosttyKit

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
                    NotificationCenter.default.post(name: .mistrySplitHorizontal, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Split Pane Vertically") {
                    NotificationCenter.default.post(name: .mistrySplitVertical, object: nil)
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
            }
        }
    }
}

extension Notification.Name {
    static let misttyNewTab = Notification.Name("misttyNewTab")
    static let mistrySplitHorizontal = Notification.Name("mistrySplitHorizontal")
    static let mistrySplitVertical = Notification.Name("mistrySplitVertical")
    static let misttySessionManager = Notification.Name("misttySessionManager")
    static let misttyClosePane = Notification.Name("misttyClosePane")
    static let misttyCloseTab = Notification.Name("misttyCloseTab")
}
