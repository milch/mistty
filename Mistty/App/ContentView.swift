import AppKit
import SwiftUI

struct ContentView: View {
  @State var store = SessionStore()
  @AppStorage("sidebarVisible") var sidebarVisible = true
  @SceneStorage("sidebarWidth") var sidebarWidth: Double = 220
  @State var showingSessionManager = false
  @State private var sessionManagerVM: SessionManagerViewModel?
  @State private var eventMonitor: Any?
  @State private var windowModeMonitor: Any?
  @State private var copyModeMonitor: Any?

  var body: some View {
    HStack(spacing: 0) {
      if sidebarVisible {
        SidebarView(
          store: store,
          width: Binding(
            get: { CGFloat(sidebarWidth) },
            set: { sidebarWidth = Double($0) }
          ))
        Divider()
      }

      Group {
        if let session = store.activeSession,
          let tab = session.activeTab
        {
          VStack(spacing: 0) {
            TabBarView(session: session)
            Divider()
            if let zoomedPane = tab.zoomedPane {
              PaneView(
                pane: zoomedPane,
                isActive: true,
                isWindowModeActive: tab.isWindowModeActive,
                copyModeState: (zoomedPane.id == tab.activePane?.id) ? tab.copyModeState : nil,
                onClose: { closePane(zoomedPane) },
                onSelect: {}
              )
            } else {
              PaneLayoutView(
                node: tab.layout.root,
                activePane: tab.activePane,
                isWindowModeActive: tab.isWindowModeActive,
                copyModeState: tab.copyModeState,
                copyModePaneID: tab.activePane?.id,
                onClosePane: { pane in closePane(pane) },
                onSelectPane: { pane in tab.activePane = pane }
              )
            }
          }
        } else {
          VStack(spacing: 12) {
            Text("No active session")
              .font(.title2)
              .foregroundStyle(.secondary)
            Text("Press ⌘J to open or create a session")
              .foregroundStyle(.tertiary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .overlay {
      if showingSessionManager, let vm = sessionManagerVM {
        Color.black.opacity(0.3)
          .ignoresSafeArea()
          .onTapGesture { showingSessionManager = false }

        SessionManagerView(
          vm: vm,
          isPresented: $showingSessionManager
        )
      }
    }
    .onChange(of: showingSessionManager) { _, isShowing in
      if isShowing {
        let vm = SessionManagerViewModel(store: store)
        sessionManagerVM = vm
        installKeyMonitor(vm: vm)
      } else {
        removeKeyMonitor()
        sessionManagerVM = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .misttyNewTab)) { _ in
      store.activeSession?.addTab()
    }
    .onReceive(NotificationCenter.default.publisher(for: .mistrySplitHorizontal)) { _ in
      store.activeSession?.activeTab?.splitActivePane(direction: .horizontal)
    }
    .onReceive(NotificationCenter.default.publisher(for: .mistrySplitVertical)) { _ in
      store.activeSession?.activeTab?.splitActivePane(direction: .vertical)
    }
    .onReceive(NotificationCenter.default.publisher(for: .misttySessionManager)) { _ in
      showingSessionManager = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .misttyClosePane)) { _ in
      guard let tab = store.activeSession?.activeTab,
        let pane = tab.activePane
      else { return }
      closePane(pane)
    }
    .onReceive(NotificationCenter.default.publisher(for: .misttyWindowMode)) { _ in
      guard let tab = store.activeSession?.activeTab else { return }
      tab.isWindowModeActive.toggle()
      if tab.isWindowModeActive {
        installWindowModeMonitor()
      } else {
        removeWindowModeMonitor()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .misttyCopyMode)) { _ in
      guard let tab = store.activeSession?.activeTab else { return }
      if tab.isCopyModeActive {
        exitCopyMode()
      } else {
        enterCopyMode()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .misttyCloseTab)) { _ in
      guard let session = store.activeSession,
        let tab = session.activeTab
      else { return }
      session.closeTab(tab)
      if session.tabs.isEmpty {
        store.closeSession(session)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .ghosttySetTitle)) { notification in
      guard let paneID = notification.userInfo?["paneID"] as? UUID,
        let title = notification.userInfo?["title"] as? String
      else { return }
      // Find the tab containing this pane and update its title
      for session in store.sessions {
        for tab in session.tabs {
          if tab.panes.contains(where: { $0.id == paneID }) {
            tab.title = title
            return
          }
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .ghosttyRingBell)) { notification in
      guard let paneID = notification.userInfo?["paneID"] as? UUID else { return }
      for session in store.sessions {
        for tab in session.tabs {
          if tab.panes.contains(where: { $0.id == paneID }),
            !(store.activeSession?.id == session.id && session.activeTab?.id == tab.id)
          {
            tab.hasBell = true
          }
        }
      }
    }
    .onChange(of: store.activeSession?.activeTab?.id) { _, _ in
      store.activeSession?.activeTab?.hasBell = false
    }
    .onReceive(NotificationCenter.default.publisher(for: .ghosttyCloseSurface)) { notification in
      guard let paneID = notification.userInfo?["paneID"] as? UUID else { return }
      // Find and close the pane whose shell exited
      for session in store.sessions {
        for tab in session.tabs {
          if let pane = tab.panes.first(where: { $0.id == paneID }) {
            closePaneInTab(pane, tab: tab, session: session)
            return
          }
        }
      }
    }
  }

  private func closePane(_ pane: MisttyPane) {
    guard let session = store.activeSession,
      let tab = session.activeTab
    else { return }
    closePaneInTab(pane, tab: tab, session: session)
  }

  private func closePaneInTab(_ pane: MisttyPane, tab: MisttyTab, session: MisttySession) {
    tab.closePane(pane)
    if tab.panes.isEmpty {
      session.closeTab(tab)
      if session.tabs.isEmpty {
        store.closeSession(session)
      }
    }
  }

  private func installKeyMonitor(vm: SessionManagerViewModel) {
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      switch event.keyCode {
      case 53:  // Escape
        showingSessionManager = false
        return nil
      case 36:  // Return
        vm.confirmSelection()
        showingSessionManager = false
        return nil
      case 126:  // Up arrow
        vm.moveUp()
        return nil
      case 125:  // Down arrow
        vm.moveDown()
        return nil
      default:
        break
      }

      if event.modifierFlags.contains(.control) {
        if event.charactersIgnoringModifiers == "j" {
          vm.moveDown()
          return nil
        } else if event.charactersIgnoringModifiers == "k" {
          vm.moveUp()
          return nil
        }
      }

      return event
    }
  }

  private func removeKeyMonitor() {
    if let monitor = eventMonitor {
      NSEvent.removeMonitor(monitor)
      eventMonitor = nil
    }
  }

  private func installWindowModeMonitor() {
    windowModeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // Cmd+Arrow to resize
      if event.modifierFlags.contains(.command) {
        switch event.keyCode {
        case 123:  // Cmd+Left — shrink
          resizeActivePane(delta: -0.05)
          return nil
        case 124:  // Cmd+Right — grow
          resizeActivePane(delta: 0.05)
          return nil
        case 126:  // Cmd+Up — shrink
          resizeActivePane(delta: -0.05)
          return nil
        case 125:  // Cmd+Down — grow
          resizeActivePane(delta: 0.05)
          return nil
        default: break
        }
      }

      switch event.keyCode {
      case 53:  // Escape — exit window mode
        store.activeSession?.activeTab?.isWindowModeActive = false
        removeWindowModeMonitor()
        return nil
      case 123:  // Left arrow
        navigatePane(.left)
        return nil
      case 124:  // Right arrow
        navigatePane(.right)
        return nil
      case 126:  // Up arrow
        navigatePane(.up)
        return nil
      case 125:  // Down arrow
        navigatePane(.down)
        return nil
      case 6:  // z — zoom toggle
        toggleZoom()
        return nil
      case 11:  // b — break pane to new tab
        breakPaneToTab()
        return nil
      case 15:  // r — rotate split direction
        rotateActivePane()
        return nil
      default:
        return event
      }
    }
  }

  private func breakPaneToTab() {
    guard let session = store.activeSession,
      let tab = session.activeTab,
      let pane = tab.activePane,
      tab.panes.count > 1
    else { return }  // Don't break if it's the only pane
    tab.closePane(pane)
    if tab.panes.isEmpty { session.closeTab(tab) }
    session.addTabWithPane(pane)
  }

  private func toggleZoom() {
    guard let tab = store.activeSession?.activeTab else { return }
    if tab.zoomedPane != nil {
      tab.zoomedPane = nil
    } else {
      tab.zoomedPane = tab.activePane
    }
  }

  private func navigatePane(_ direction: NavigationDirection) {
    guard let tab = store.activeSession?.activeTab,
      let current = tab.activePane,
      let target = tab.layout.adjacentPane(from: current, direction: direction)
    else { return }
    tab.activePane = target
    target.surfaceView.window?.makeFirstResponder(target.surfaceView)
  }

  private func rotateActivePane() {
    guard let tab = store.activeSession?.activeTab,
      let pane = tab.activePane
    else { return }
    tab.layout.rotateDirection(containing: pane)
  }

  private func resizeActivePane(delta: CGFloat) {
    guard let tab = store.activeSession?.activeTab,
      let pane = tab.activePane
    else { return }
    tab.layout.resizeSplit(containing: pane, delta: delta)
  }

  private func removeWindowModeMonitor() {
    if let monitor = windowModeMonitor {
      NSEvent.removeMonitor(monitor)
      windowModeMonitor = nil
    }
  }

  // MARK: - Copy Mode

  private func enterCopyMode() {
    guard let tab = store.activeSession?.activeTab else { return }
    // TODO: get actual terminal dimensions from ghostty
    tab.copyModeState = CopyModeState(rows: 24, cols: 80)
    installCopyModeMonitor()
  }

  private func exitCopyMode() {
    store.activeSession?.activeTab?.copyModeState = nil
    removeCopyModeMonitor()
  }

  private func installCopyModeMonitor() {
    copyModeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard var state = store.activeSession?.activeTab?.copyModeState else { return event }

      switch event.keyCode {
      case 53:  // Escape
        exitCopyMode()
        return nil
      default: break
      }

      guard let chars = event.characters else { return event }
      switch chars {
      case "h": state.moveLeft()
      case "j": state.moveDown()
      case "k": state.moveUp()
      case "l": state.moveRight()
      case "0": state.moveToLineStart()
      case "$": state.moveToLineEnd()
      case "G": state.moveToBottom()
      case "g": state.moveToTop()
      case "v": state.toggleSelection()
      case "y":
        yankSelection()
        exitCopyMode()
        return nil
      default: break
      }

      store.activeSession?.activeTab?.copyModeState = state
      return nil
    }
  }

  private func removeCopyModeMonitor() {
    if let monitor = copyModeMonitor {
      NSEvent.removeMonitor(monitor)
      copyModeMonitor = nil
    }
  }

  private func yankSelection() {
    guard let tab = store.activeSession?.activeTab,
      let state = tab.copyModeState,
      let range = state.selectionRange
    else { return }
    // TODO: Read selected text from ghostty surface using ghostty_surface_read_text
    // once the API is available. For now, log the selection range.
    _ = range
  }
}
