import AppKit
import MisttyShared
import SwiftUI

struct WindowRootView: View {
  let windowsStore: WindowsStore
  let config: MisttyConfig
  @State private var state: WindowState?
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Group {
      if let state {
        ContentView(state: state, windowsStore: windowsStore, config: config)
      } else {
        Color.clear
      }
    }
    .onAppear {
      claimOrCreateState()
      // Capture the openWindow action once. Subsequent captures are no-ops
      // (the action is value-typed and stable across mounts).
      if windowsStore.openWindowAction == nil {
        windowsStore.openWindowAction = openWindow
      }
      windowsStore.drainPendingRestores()
      windowsStore.applyPendingActiveWindow()
    }
    .background(
      WindowAccessor { window in
        guard let window, let state else { return }
        _ = windowsStore.registerNSWindow(window, for: state)
      }
    )
  }

  private func claimOrCreateState() {
    if !windowsStore.pendingRestoreStates.isEmpty {
      let claimed = windowsStore.pendingRestoreStates.removeFirst()
      // Restored states aren't yet in `windows`; the registerRestoredWindow
      // call adds them to the registry.
      windowsStore.registerRestoredWindow(claimed)
      state = claimed
      return
    }
    state = windowsStore.createWindow()
  }
}
