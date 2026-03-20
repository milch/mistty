import AppKit
import GhosttyKit
import MisttyShared
import SwiftUI

struct ContentView: View {
  var store: SessionStore
  @AppStorage("sidebarVisible") var sidebarVisible = true
  @SceneStorage("sidebarWidth") var sidebarWidth: Double = 220
  @State var showingSessionManager = false
  @State private var sessionManagerVM: SessionManagerViewModel?
  @State private var eventMonitor: Any?
  @State private var windowModeMonitor: Any?
  @State private var copyModeMonitor: Any?
  @State private var ctrlNavMonitor: Any?

  var body: some View {
    contentWithNotifications
      .onReceive(NotificationCenter.default.publisher(for: .misttyFocusTabByIndex)) {
        notification in
        guard let session = store.activeSession,
          let index = notification.userInfo?["index"] as? Int,
          index < session.tabs.count
        else { return }
        session.activeTab = session.tabs[index]
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyNextTab)) { _ in
        store.activeSession?.nextTab()
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyPrevTab)) { _ in
        store.activeSession?.prevTab()
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyNextSession)) { _ in
        store.nextSession()
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyPrevSession)) { _ in
        store.prevSession()
      }
  }

  private var contentWithNotifications: some View {
    contentWithOverlays
      .onReceive(NotificationCenter.default.publisher(for: .misttyPopupToggle)) { notification in
        handlePopupToggle(notification)
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyClosePane)) { _ in
        handleClosePane()
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyWindowMode)) { _ in
        handleWindowMode()
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyCopyMode)) { _ in
        handleCopyMode()
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyCloseTab)) { _ in
        handleCloseTab()
      }
      .onReceive(NotificationCenter.default.publisher(for: .ghosttySetTitle)) { notification in
        handleSetTitle(notification)
      }
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyRingBell)) { notification in
        handleRingBell(notification)
      }
      .onChange(of: store.activeSession?.activeTab?.id) { _, _ in
        store.activeSession?.activeTab?.hasBell = false
      }
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyCloseSurface)) { notification in
        handleCloseSurface(notification)
      }
  }

  private var contentWithOverlays: some View {
    mainContent
      .overlay { sessionManagerOverlay }
      .overlay { popupOverlay }
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
      .onReceive(NotificationCenter.default.publisher(for: .misttySplitHorizontal)) { _ in
        splitPane(direction: .horizontal)
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttySplitVertical)) { _ in
        splitPane(direction: .vertical)
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttySessionManager)) { _ in
        showingSessionManager = true
      }
  }

  @ViewBuilder
  private var mainContent: some View {
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
            let joinPickTabNames = session.tabs
              .filter { $0.id != tab.id }
              .map { $0.displayTitle }
            ZStack(alignment: .bottom) {
              if let zoomedPane = tab.zoomedPane {
                PaneView(
                  pane: zoomedPane,
                  isActive: true,
                  isWindowModeActive: tab.isWindowModeActive,
                  isZoomed: true,
                  copyModeState: (zoomedPane.id == tab.activePane?.id) ? tab.copyModeState : nil,
                  windowModeState: tab.windowModeState,
                  joinPickTabNames: joinPickTabNames,
                  paneCount: tab.panes.count,
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
                  windowModeState: tab.windowModeState,
                  joinPickTabNames: joinPickTabNames,
                  paneCount: tab.panes.count,
                  onClosePane: { pane in closePane(pane) },
                  onSelectPane: { pane in tab.activePane = pane }
                )
              }
              if tab.windowModeState != .inactive {
                WindowModeHints(
                  isJoinPick: tab.windowModeState == .joinPick,
                  tabNames: joinPickTabNames,
                  paneCount: tab.panes.count
                )
                .padding(6)
                .allowsHitTesting(false)
              }
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
    .onAppear {
      DispatchQueue.main.async {
        if let window = NSApplication.shared.keyWindow {
          _ = store.registerWindow(window)
        }
      }
      if ctrlNavMonitor == nil {
        installCtrlNavMonitor()
      }
    }
    .onDisappear {
      DispatchQueue.main.async { [store] in
        for tracked in store.trackedWindows where !tracked.window.isVisible {
          store.unregisterWindow(tracked.window)
        }
      }
      removeKeyMonitor()
      removeWindowModeMonitor()
      removeCopyModeMonitor()
      removeCtrlNavMonitor()
      store.activeSession?.activeTab?.windowModeState = .inactive
      if store.activeSession?.activeTab?.isCopyModeActive == true {
        exitCopyMode()
      }
      showingSessionManager = false
    }
  }

  @ViewBuilder
  private var sessionManagerOverlay: some View {
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

  @ViewBuilder
  private var popupOverlay: some View {
    if let session = store.activeSession,
      let popup = session.activePopup,
      popup.isVisible
    {
      GeometryReader { geometry in
        PopupOverlayView(
          popup: popup,
          onDismiss: {
            session.hideActivePopup()
            returnFocusToActivePane()
          },
          onClose: {
            session.closePopup(popup)
            returnFocusToActivePane()
          }
        )
        .frame(
          width: geometry.size.width * popup.definition.width,
          height: geometry.size.height * popup.definition.height
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func splitPane(direction: SplitDirection) {
    guard let session = store.activeSession,
      let tab = session.activeTab
    else { return }
    if let sshCommand = session.sshCommand,
      !NSEvent.modifierFlags.contains(.option)
    {
      let pane = MisttyPane(id: tab.paneIDGenerator())
      pane.directory = session.directory
      pane.command = sshCommand
      pane.useCommandField = false
      tab.addExistingPane(pane, direction: direction)
    } else {
      tab.splitActivePane(direction: direction)
    }
  }

  private func closePane(_ pane: MisttyPane) {
    guard let session = store.activeSession,
      let tab = session.activeTab
    else { return }
    closePaneInTab(pane, tab: tab, session: session)
  }

  private func returnFocusToActivePane() {
    if let pane = store.activeSession?.activeTab?.activePane {
      DispatchQueue.main.async {
        pane.surfaceView.window?.makeFirstResponder(pane.surfaceView)
      }
    }
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

  // MARK: - Notification Handlers

  private func handlePopupToggle(_ notification: Notification) {
    guard let session = store.activeSession,
      let name = notification.userInfo?["name"] as? String
    else { return }
    let config = MisttyConfig.load()
    guard let definition = config.popups.first(where: { $0.name == name }) else { return }
    session.togglePopup(definition: definition)
    if let popup = session.activePopup, popup.isVisible {
      DispatchQueue.main.async {
        popup.pane.surfaceView.window?.makeFirstResponder(popup.pane.surfaceView)
      }
    }
  }

  private func handleClosePane() {
    if let session = store.activeSession,
      let popup = session.activePopup,
      popup.isVisible
    {
      session.closePopup(popup)
      returnFocusToActivePane()
      return
    }
    guard let tab = store.activeSession?.activeTab,
      let pane = tab.activePane
    else { return }
    closePane(pane)
  }

  private func handleWindowMode() {
    guard let tab = store.activeSession?.activeTab else { return }
    if tab.isWindowModeActive {
      tab.windowModeState = .inactive
      removeWindowModeMonitor()
    } else {
      tab.windowModeState = .normal
      installWindowModeMonitor()
    }
  }

  private func handleCopyMode() {
    guard let tab = store.activeSession?.activeTab else { return }
    if tab.isCopyModeActive {
      exitCopyMode()
    } else {
      enterCopyMode()
    }
  }

  private func handleCloseTab() {
    guard let session = store.activeSession,
      let tab = session.activeTab
    else { return }
    session.closeTab(tab)
    if session.tabs.isEmpty {
      store.closeSession(session)
    }
  }

  private func handleSetTitle(_ notification: Notification) {
    guard let paneID = notification.userInfo?["paneID"] as? Int,
      let title = notification.userInfo?["title"] as? String
    else { return }
    for session in store.sessions {
      for tab in session.tabs {
        if let pane = tab.panes.first(where: { $0.id == paneID }) {
          pane.processTitle = title
          tab.title = title
          return
        }
      }
    }
  }

  private func handleRingBell(_ notification: Notification) {
    guard let paneID = notification.userInfo?["paneID"] as? Int else { return }
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

  private func handleCloseSurface(_ notification: Notification) {
    guard let paneID = notification.userInfo?["paneID"] as? Int else { return }
    // Check if this is a popup pane
    for session in store.sessions {
      if let popup = session.popups.first(where: { $0.pane.id == paneID }) {
        if popup.definition.closeOnExit {
          session.closePopup(popup)
        } else {
          popup.isVisible = false
          if session.activePopup?.id == popup.id {
            session.activePopup = nil
          }
        }
        returnFocusToActivePane()
        return
      }
    }
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

  // MARK: - Key Monitors

  private func installKeyMonitor(vm: SessionManagerViewModel) {
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      switch event.keyCode {
      case 53:  // Escape
        showingSessionManager = false
        return nil
      case 36:  // Return
        vm.confirmSelection(modifierFlags: event.modifierFlags)
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
    if store.activeSession?.activeTab?.isCopyModeActive == true {
      exitCopyMode()
    }
    windowModeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // Join-pick mode: number keys select target tab
      if store.activeSession?.activeTab?.windowModeState == .joinPick {
        if event.keyCode == 53 {  // Escape — back to normal window mode
          store.activeSession?.activeTab?.windowModeState = .normal
          return nil
        }
        if let chars = event.characters, let num = Int(chars), num >= 1, num <= 9 {
          joinPaneToTab(targetIndex: num - 1)
          return nil
        }
        return nil  // Consume all other keys in join-pick mode
      }

      // Cmd+Arrow to resize
      if event.modifierFlags.contains(.command) {
        switch event.keyCode {
        case 123:  // Cmd+Left — shrink horizontal
          resizeActivePane(delta: -0.05, along: .horizontal)
          return nil
        case 124:  // Cmd+Right — grow horizontal
          resizeActivePane(delta: 0.05, along: .horizontal)
          return nil
        case 126:  // Cmd+Up — shrink vertical
          resizeActivePane(delta: -0.05, along: .vertical)
          return nil
        case 125:  // Cmd+Down — grow vertical
          resizeActivePane(delta: 0.05, along: .vertical)
          return nil
        default: break
        }
      }

      switch event.keyCode {
      case 53:  // Escape — exit window mode
        store.activeSession?.activeTab?.windowModeState = .inactive
        removeWindowModeMonitor()
        return nil
      case 123:  // Left arrow
        swapActivePane(.left)
        return nil
      case 124:  // Right arrow
        swapActivePane(.right)
        return nil
      case 126:  // Up arrow
        swapActivePane(.up)
        return nil
      case 125:  // Down arrow
        swapActivePane(.down)
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
      case 46:  // m — join pane to tab
        guard let tab = store.activeSession?.activeTab else { return nil }
        tab.windowModeState = .joinPick
        return nil
      case 18, 19, 20, 21, 23:  // 1-5: standard layouts
        if let tab = store.activeSession?.activeTab, tab.panes.count >= 2 {
          let standardLayout: StandardLayout =
            switch event.keyCode {
            case 18: .evenHorizontal
            case 19: .evenVertical
            case 20: .mainHorizontal
            case 21: .mainVertical
            case 23: .tiled
            default: .evenHorizontal
            }
          tab.applyStandardLayout(standardLayout)
          tab.windowModeState = .inactive
          removeWindowModeMonitor()
        }
        return nil
      default:
        return event
      }
    }
  }

  private func joinPaneToTab(targetIndex: Int) {
    guard let session = store.activeSession,
      let sourceTab = session.activeTab,
      let pane = sourceTab.activePane
    else { return }
    let targetTabs = session.tabs.filter { $0.id != sourceTab.id }
    guard targetIndex < targetTabs.count else { return }
    let targetTab = targetTabs[targetIndex]

    // Exit window mode before modifying tabs
    sourceTab.windowModeState = .inactive
    removeWindowModeMonitor()

    sourceTab.closePane(pane)
    if sourceTab.panes.isEmpty { session.closeTab(sourceTab) }
    targetTab.addExistingPane(pane, direction: .horizontal)
    session.activeTab = targetTab
  }

  private func breakPaneToTab() {
    guard let session = store.activeSession,
      let tab = session.activeTab,
      let pane = tab.activePane,
      tab.panes.count > 1
    else { return }  // Don't break if it's the only pane

    tab.windowModeState = .inactive
    removeWindowModeMonitor()

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

  private func swapActivePane(_ direction: NavigationDirection) {
    guard let tab = store.activeSession?.activeTab,
      let current = tab.activePane
    else { return }
    tab.layout.swapPane(current, direction: direction)
  }

  private func rotateActivePane() {
    guard let tab = store.activeSession?.activeTab,
      let pane = tab.activePane
    else { return }
    tab.layout.rotateDirection(containing: pane)
  }

  private func resizeActivePane(delta: CGFloat, along direction: SplitDirection) {
    guard let tab = store.activeSession?.activeTab,
      let pane = tab.activePane
    else { return }
    tab.layout.resizeSplit(containing: pane, delta: delta, along: direction)
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
    if tab.isWindowModeActive {
      tab.windowModeState = .inactive
      removeWindowModeMonitor()
    }

    // Get actual terminal dimensions and cursor position from ghostty
    var rows = 24
    var cols = 80
    var cursorRow: Int?
    var cursorCol: Int?
    if let surfaceView = tab.activePane?.surfaceView {
      if let surface = surfaceView.surface {
        let size = ghostty_surface_size(surface)
        rows = Int(size.rows)
        cols = Int(size.columns)
      }
      if let pos = surfaceView.cursorPosition() {
        cursorRow = pos.row
        cursorCol = pos.col
      }
    }

    tab.copyModeState = CopyModeState(
      rows: rows, cols: cols, cursorRow: cursorRow, cursorCol: cursorCol)
    installCopyModeMonitor()
  }

  private func scrollViewport(_ state: inout CopyModeState, delta: Int) {
    guard let pane = store.activeSession?.activeTab?.activePane,
          let surface = pane.surfaceView.surface else { return }
    let actionStr = "scroll_page_lines:\(delta)"
    _ = ghostty_surface_binding_action(surface, actionStr, UInt(actionStr.utf8.count))
    if let anchor = state.anchor {
      state.anchor = (row: anchor.row - delta, col: anchor.col)
    }
  }

  private func exitCopyMode() {
    // Scroll back to bottom (active area) when leaving copy mode
    if let pane = store.activeSession?.activeTab?.activePane,
       let surface = pane.surfaceView.surface {
      let actionStr = "scroll_to_bottom"
      _ = ghostty_surface_binding_action(surface, actionStr, UInt(actionStr.utf8.count))
    }
    store.activeSession?.activeTab?.copyModeState = nil
    removeCopyModeMonitor()
  }

  private func installCopyModeMonitor() {
    copyModeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard var state = store.activeSession?.activeTab?.copyModeState else { return event }

      // Pass through system shortcuts (Cmd+*) when not searching
      if event.modifierFlags.contains(.command) && !state.isSearching {
        return event
      }

      // Extract key from charactersIgnoringModifiers for correct Ctrl-v handling
      guard let keyStr = event.charactersIgnoringModifiers, let key = keyStr.first else {
        return event
      }

      let lineReader: (Int) -> String? = { row in
        self.readTerminalLine(row: row)
      }

      let actions = state.handleKey(
        key: key,
        keyCode: event.keyCode,
        modifiers: event.modifierFlags,
        lineReader: lineReader
      )

      // Apply actions
      for action in actions {
        switch action {
        case .cursorMoved:
          break  // Position already in state
        case .updateSelection:
          break  // Selection derived from state
        case .yank:
          break  // Not used — yank is signaled by exitCopyMode
        case .exitCopyMode:
          // Yank if there's a selection before exiting
          if state.isSelecting {
            store.activeSession?.activeTab?.copyModeState = state
            yankSelection()
          }
          exitCopyMode()
          return nil
        case .enterSubMode:
          break  // Sub-mode already in state
        case .showHelp, .hideHelp:
          break  // showingHelp already in state
        case .startSearch:
          break  // subMode already set to search
        case .updateSearch:
          break  // searchQuery already updated
        case .confirmSearch:
          performSearch(&state)
          countSearchMatches(&state)
        case .cancelSearch:
          break  // Already handled in state
        case .searchNext:
          performSearch(&state)
        case .searchPrev:
          let original = state.searchDirection
          state.searchDirection = original == .forward ? .reverse : .forward
          performSearch(&state)
          state.searchDirection = original
        case .scroll(let deltaRows):
          scrollViewport(&state, delta: deltaRows)
        case .needsContinuation:
          let continuationActions = state.continuePendingMotion(lineReader: lineReader)
          for contAction in continuationActions {
            switch contAction {
            case .scroll(let delta):
              scrollViewport(&state, delta: delta)
            case .needsContinuation:
              let more = state.continuePendingMotion(lineReader: lineReader)
              for a in more {
                if case .scroll(let d) = a {
                  scrollViewport(&state, delta: d)
                }
              }
            default:
              break
            }
          }
        }
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

  // MARK: - Ctrl Nav Monitor

  private func installCtrlNavMonitor() {
    ctrlNavMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.modifierFlags.contains(.control),
        let chars = event.charactersIgnoringModifiers?.lowercased()
      else { return event }

      let direction: NavigationDirection
      switch chars {
      case "h": direction = .left
      case "j": direction = .down
      case "k": direction = .up
      case "l": direction = .right
      default: return event
      }

      // Don't intercept if session manager, window mode, or copy mode is active
      guard !showingSessionManager,
        store.activeSession?.activeTab?.isWindowModeActive != true,
        store.activeSession?.activeTab?.isCopyModeActive != true
      else { return event }

      guard let tab = store.activeSession?.activeTab,
        let pane = tab.activePane
      else { return event }

      // If running neovim, let the keypress through for smart-splits
      if pane.isRunningNeovim { return event }

      // Navigate between MistTY panes — only consume if navigation succeeds
      if let target = tab.layout.adjacentPane(from: pane, direction: direction) {
        tab.activePane = target
        DispatchQueue.main.async {
          target.surfaceView.window?.makeFirstResponder(target.surfaceView)
        }
        return nil  // Consume the event
      }
      return event  // No adjacent pane, pass through to terminal
    }
  }

  private func removeCtrlNavMonitor() {
    if let monitor = ctrlNavMonitor {
      NSEvent.removeMonitor(monitor)
      ctrlNavMonitor = nil
    }
  }

  private func performSearch(_ state: inout CopyModeState) {
    guard !state.searchQuery.isEmpty,
      let pane = store.activeSession?.activeTab?.activePane,
      let surface = pane.surfaceView.surface
    else { return }

    let scrollbar = pane.surfaceView.scrollbarState
    let totalRows = Int(scrollbar.total)
    let viewportOffset = Int(scrollbar.offset)
    let cols = Int(ghostty_surface_size(surface).columns)
    guard totalRows > 0 else { return }

    // Convert cursor to screen coordinates
    let cursorScreenRow = state.cursorRow + viewportOffset
    let isForward = state.searchDirection == .forward

    // Scan from cursor position in the search direction, wrapping around
    for i in 1...totalRows {
      let screenRow: Int
      if isForward {
        screenRow = (cursorScreenRow + i) % totalRows
      } else {
        screenRow = (cursorScreenRow - i + totalRows) % totalRows
      }

      guard let line = readScreenLine(row: screenRow) else { continue }

      let options: String.CompareOptions = isForward
        ? .caseInsensitive
        : [.caseInsensitive, .backwards]

      if let range = line.range(of: state.searchQuery, options: options) {
        let col = line.distance(from: line.startIndex, to: range.lowerBound)

        // Scroll to make the match visible — center it in viewport
        let viewportRows = Int(scrollbar.len)
        let targetOffset = max(0, min(screenRow - viewportRows / 2, totalRows - viewportRows))
        let actionStr = "scroll_to_row:\(targetOffset)"
        _ = ghostty_surface_binding_action(surface, actionStr, UInt(actionStr.utf8.count))

        // Set cursor to viewport-relative position
        state.cursorRow = screenRow - targetOffset
        state.cursorCol = min(col, cols - 1)
        state.desiredCol = nil
        return
      }
    }
  }

  private func countSearchMatches(_ state: inout CopyModeState) {
    guard !state.searchQuery.isEmpty,
      let pane = store.activeSession?.activeTab?.activePane
    else { return }

    let scrollbar = pane.surfaceView.scrollbarState
    let totalRows = Int(scrollbar.total)
    let viewportOffset = Int(scrollbar.offset)
    let cursorScreenRow = state.cursorRow + viewportOffset

    var total = 0
    var currentIndex = 0

    for row in 0..<totalRows {
      guard let line = readScreenLine(row: row) else { continue }
      var searchStart = line.startIndex
      while let range = line.range(
        of: state.searchQuery, options: .caseInsensitive,
        range: searchStart..<line.endIndex)
      {
        total += 1
        let matchCol = line.distance(from: line.startIndex, to: range.lowerBound)
        if row < cursorScreenRow || (row == cursorScreenRow && matchCol <= state.cursorCol) {
          currentIndex = total
        }
        searchStart = range.upperBound
      }
    }

    state.searchMatchTotal = total > 0 ? total : nil
    state.searchMatchIndex = total > 0 ? currentIndex : nil
  }

  private func readTerminalLine(row: Int) -> String? {
    guard let pane = store.activeSession?.activeTab?.activePane,
      let surface = pane.surfaceView.surface
    else { return nil }

    let size = ghostty_surface_size(surface)

    var sel = ghostty_selection_s()
    sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
    sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
    sel.top_left.x = 0
    sel.top_left.y = UInt32(row)
    sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
    sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
    sel.bottom_right.x = UInt32(size.columns - 1)
    sel.bottom_right.y = UInt32(row)
    sel.rectangle = false

    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let ptr = text.text else { return nil }
    return String(cString: ptr)
  }

  private func readScreenLine(row: Int) -> String? {
    guard let pane = store.activeSession?.activeTab?.activePane,
      let surface = pane.surfaceView.surface
    else { return nil }

    let size = ghostty_surface_size(surface)

    var sel = ghostty_selection_s()
    sel.top_left.tag = GHOSTTY_POINT_SCREEN
    sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
    sel.top_left.x = 0
    sel.top_left.y = UInt32(row)
    sel.bottom_right.tag = GHOSTTY_POINT_SCREEN
    sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
    sel.bottom_right.x = UInt32(size.columns - 1)
    sel.bottom_right.y = UInt32(row)
    sel.rectangle = false

    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let ptr = text.text else { return nil }
    return String(cString: ptr)
  }

  private func yankSelection() {
    guard let tab = store.activeSession?.activeTab,
      let pane = tab.activePane,
      let state = tab.copyModeState,
      let anchor = state.anchor,
      let surface = pane.surfaceView.surface
    else { return }

    let size = ghostty_surface_size(surface)
    let cols = Int(size.columns)
    var textToCopy: String?

    let anchorOutOfViewport = anchor.row < 0 || anchor.row >= state.rows
    let useScreenCoords = anchorOutOfViewport
    let tag: ghostty_point_tag_e = useScreenCoords ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
    let offset = useScreenCoords ? Int(pane.surfaceView.scrollbarState.offset) : 0

    switch state.subMode {
    case .visual:
      // Character-wise: read from anchor to cursor
      textToCopy = readGhosttyText(
        surface: surface,
        startRow: anchor.row + offset, startCol: anchor.col,
        endRow: state.cursorRow + offset, endCol: state.cursorCol,
        rectangle: false,
        pointTag: tag
      )

    case .visualLine:
      // Line-wise: full lines from min to max row
      let minRow = min(anchor.row, state.cursorRow)
      let maxRow = max(anchor.row, state.cursorRow)
      textToCopy = readGhosttyText(
        surface: surface,
        startRow: minRow + offset, startCol: 0,
        endRow: maxRow + offset, endCol: cols - 1,
        rectangle: false,
        pointTag: tag
      )

    case .visualBlock:
      // Block-wise: read each row's slice, joined by newlines
      let minRow = min(anchor.row, state.cursorRow)
      let maxRow = max(anchor.row, state.cursorRow)
      let minCol = min(anchor.col, state.cursorCol)
      var lines: [String] = []
      let logicalRightCol = max(anchor.col, state.cursorCol)
      for row in minRow...maxRow {
        let readRow = row + offset
        let line: String?
        if useScreenCoords {
          line = readScreenLine(row: readRow)
        } else {
          line = readTerminalLine(row: readRow)
        }
        if let line = line {
          let contentEnd = WordMotion.lastNonWhitespaceIndex(in: line)
          guard contentEnd >= minCol else {
            lines.append("")
            continue
          }
          let rightCol = min(logicalRightCol, contentEnd)
          let chars = Array(line)
          let start = min(minCol, chars.count)
          let end = min(rightCol + 1, chars.count)
          if start < end {
            lines.append(String(chars[start..<end]))
          } else {
            lines.append("")
          }
        }
      }
      textToCopy = lines.joined(separator: "\n")

    default:
      return
    }

    if let text = textToCopy, !text.isEmpty {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
  }

  private func readGhosttyText(
    surface: ghostty_surface_t,
    startRow: Int, startCol: Int,
    endRow: Int, endCol: Int,
    rectangle: Bool,
    pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT
  ) -> String? {
    var sel = ghostty_selection_s()
    sel.top_left.tag = pointTag
    sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
    sel.top_left.x = UInt32(startCol)
    sel.top_left.y = UInt32(startRow)
    sel.bottom_right.tag = pointTag
    sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
    sel.bottom_right.x = UInt32(endCol)
    sel.bottom_right.y = UInt32(endRow)
    sel.rectangle = rectangle

    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let ptr = text.text else { return nil }
    return String(cString: ptr)
  }
}
