import SwiftUI
import GhosttyKit

@main
struct MisttyApp: App {
    init() {
        _ = GhosttyAppManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
