import AppKit
import GhosttyKit
import MisttyShared
import SwiftUI

struct ContentView: View {
  var store: SessionStore
  var config: MisttyConfig
  @AppStorage("sidebarVisible") var sidebarVisible = true
  @State private var tabBarOverride: TabBarVisibilityOverride = .auto
  @SceneStorage("sidebarWidth") var sidebarWidth: Double = 220
  @State var showingSessionManager = false
  @State private var sessionManagerVM: SessionManagerViewModel?
  @State private var eventMonitor: Any?
  @State private var windowModeMonitor: Any?
  @State private var previousActiveTab: MisttyTab?
  @State private var copyModeMonitor: Any?
  @State private var ctrlNavMonitor: Any?
  @State private var closeMonitor: Any?
  @State private var altShortcutMonitor: Any?
  @State private var windowModeShortcutMonitor: Any?

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
      .onReceive(NotificationCenter.default.publisher(for: .misttyFocusSessionByIndex)) {
        notification in
        guard let index = notification.userInfo?["index"] as? Int,
          index < store.sessions.count
        else { return }
        store.activeSession = store.sessions[index]
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
      .onReceive(NotificationCenter.default.publisher(for: .misttyMoveSessionUp)) { _ in
        store.moveActiveSessionUp()
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyMoveSessionDown)) { _ in
        store.moveActiveSessionDown()
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
      .onReceive(NotificationCenter.default.publisher(for: .misttyYankHints)) { _ in
        handleYankHints()
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyScrollChanged)) { _ in
        guard var state = store.activeSession?.activeTab?.copyModeState,
              state.isHinting,
              let source = state.hint?.source else { return }
        populateHintMatches(&state, source: source)
        store.activeSession?.activeTab?.copyModeState = state
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
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyPwd)) { notification in
        handlePwd(notification)
      }
      .onChange(of: store.activeSession?.activeTab?.id) { _, _ in
        store.activeSession?.activeTab?.hasBell = false
        updateDockBadge()
        // Window mode is ephemeral (tmux-style prefix). When the user switches
        // away to a different session/tab, clear it from the tab we're leaving
        // so it doesn't appear "stuck" on return — and drop the global
        // keyDown monitor, which otherwise acts on whatever tab is active
        // now (not the one we activated it for).
        let newTab = store.activeSession?.activeTab
        if let prev = previousActiveTab, prev !== newTab, prev.isWindowModeActive {
          prev.windowModeState = .inactive
        }
        if newTab?.isWindowModeActive != true {
          removeWindowModeMonitor()
        }
        previousActiveTab = newTab
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
          // The session manager's NSTextField holds first responder while
          // open; without an explicit hand-back AppKit leaves the text
          // field as first responder even after SwiftUI tears the overlay
          // down. The Edit menu's default Cmd-X → Cut shortcut then wins
          // over our "Window Mode" equivalent (both bound to Cmd-X), so
          // window mode appears to ignore the shortcut until something
          // else forces focus back to the terminal.
          returnFocusToActivePane()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyNewTab)) { _ in
        addTab(inheritSsh: true)
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyNewTabPlain)) { _ in
        addTab(inheritSsh: false)
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttySplitHorizontal)) { _ in
        splitPane(direction: .horizontal, inheritSsh: true)
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttySplitHorizontalPlain)) { _ in
        splitPane(direction: .horizontal, inheritSsh: false)
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttySplitVertical)) { _ in
        splitPane(direction: .vertical, inheritSsh: true)
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttySplitVerticalPlain)) { _ in
        splitPane(direction: .vertical, inheritSsh: false)
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttySessionManager)) { _ in
        showingSessionManager = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyToggleTabBar)) { _ in
        let configured = configuredTabBarShow()
        withAnimation(.easeInOut(duration: 0.15)) {
          tabBarOverride = tabBarOverride.toggled(configuredShow: configured)
        }
      }
      .onChange(of: sidebarVisible) { _, _ in
        resolveOverrideIfMatched()
      }
      .onChange(of: store.activeSession?.tabs.count) { _, _ in
        resolveOverrideIfMatched()
      }
  }

  @ViewBuilder
  private var mainContent: some View {
    let tabBarShouldShow = shouldShowTabBar()
    HStack(spacing: 0) {
      if sidebarVisible {
        HStack(spacing: 0) {
          SidebarView(
            store: store,
            width: Binding(
              get: { CGFloat(sidebarWidth) },
              set: { sidebarWidth = Double($0) }
            ),
            titleBarStyle: config.ui.titleBarStyle,
            tabBarVisible: tabBarShouldShow)
          Divider()
        }
        .transition(.move(edge: .leading))
      }

      Group {
        if let session = store.activeSession,
          let tab = session.activeTab
        {
          VStack(spacing: 0) {
            if tabBarShouldShow {
              VStack(spacing: 0) {
                TabBarView(
                  session: session,
                  leadingInset:
                    (config.ui.titleBarStyle.hasTrafficLights && !sidebarVisible) ? 72 : 0
                )
                Divider()
              }
              .transition(.move(edge: .top).combined(with: .opacity))
            }
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
                  borderColor: config.ui.paneBorderColor,
                  borderWidth: CGFloat(config.ui.paneBorderWidth),
                  onClosePane: { pane in closePane(pane) },
                  onSelectPane: { pane in tab.activePane = pane },
                  onResizeBetween: { aRep, bRep, delta in
                    tab.layout.resizeSplit(between: aRep, and: bRep, delta: delta)
                  }
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
          .animation(.easeInOut(duration: 0.15), value: tabBarShouldShow)
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
    .background(
      // viewDidMoveToWindow fires synchronously as the tracking NSView is
      // mounted into the window's content hierarchy, giving us the
      // *actual* host window for this ContentView — not whatever
      // `NSApplication.shared.keyWindow` happens to return. That matters
      // during state restoration (windows exist before they become key)
      // and when multiple terminal windows coexist, both of which could
      // leave the host window unregistered so `isTerminalWindowKey()`
      // returned false and the Cmd-W fallback called
      // `NSApp.keyWindow?.performClose(nil)` — closing the whole window.
      WindowAccessor { window in
        guard let window else { return }
        _ = store.registerWindow(window)
      }
    )
    .onAppear {
      if ctrlNavMonitor == nil {
        installCtrlNavMonitor()
      }
      if closeMonitor == nil {
        installCloseMonitor()
      }
      if altShortcutMonitor == nil {
        installAltShortcutMonitor()
      }
      if windowModeShortcutMonitor == nil {
        installWindowModeShortcutMonitor()
      }
    }
    .onDisappear {
      DebugLog.shared.log(
        "view",
        "ContentView.onDisappear fired; scheduling stale-window sweep")
      DispatchQueue.main.async { [store] in
        for tracked in store.trackedWindows where !tracked.window.isVisible {
          DebugLog.shared.log(
            "view",
            "onDisappear sweep: unregistering invisible id=\(tracked.id) num=\(tracked.window.windowNumber)"
          )
          store.unregisterWindow(tracked.window)
        }
      }
      removeKeyMonitor()
      removeWindowModeMonitor()
      removeCopyModeMonitor()
      removeCtrlNavMonitor()
      removeCloseMonitor()
      removeAltShortcutMonitor()
      removeWindowModeShortcutMonitor()
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
      // Full-screen backdrop sits at this level (above the popup
      // chrome's frame) so its rectangle never has visible corners
      // adjacent to the popup. Previously the backdrop lived inside
      // PopupOverlayView and was sized to the popup frame; the user
      // saw the backdrop's sharp 90° corners around the rounded
      // chrome and read those as "sharp corners on the popup".
      ZStack {
        Color.black.opacity(0.4)
          .ignoresSafeArea()
          .onTapGesture {
            session.hideActivePopup()
            returnFocusToActivePane()
          }
        GeometryReader { geometry in
          PopupOverlayView(
            popup: popup,
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
  }

  /// Evaluates the configured `tab_bar_mode` rule against the current
  /// sidebar visibility and active session's tab count. Does not consider
  /// any user override — use this as the input to `TabBarVisibilityOverride`.
  /// Falls back to a tab count of 1 when no session is active.
  private func configuredTabBarShow() -> Bool {
    let tabCount = store.activeSession?.tabs.count ?? 1
    return config.ui.tabBarMode.shouldShow(
      sidebarVisible: sidebarVisible, tabCount: tabCount)
  }

  private func shouldShowTabBar() -> Bool {
    tabBarOverride.effectiveShow(configuredShow: configuredTabBarShow())
  }

  /// Clear the override when the configured rule would produce the same
  /// visibility we're already forcing — i.e. the override has become
  /// redundant. Called from `.onChange` on its inputs.
  private func resolveOverrideIfMatched() {
    guard tabBarOverride != .auto else { return }
    let configured = configuredTabBarShow()
    if tabBarOverride.effectiveShow(configuredShow: configured) == configured {
      tabBarOverride = .auto
    }
  }

  private func splitPane(direction: SplitDirection, inheritSsh: Bool) {
    guard let session = store.activeSession,
      let tab = session.activeTab
    else { return }
    if inheritSsh, let sshCommand = session.sshCommand {
      let pane = MisttyPane(id: tab.paneIDGenerator())
      pane.directory = session.directory
      pane.command = sshCommand
      tab.addExistingPane(pane, direction: direction)
    } else {
      tab.splitActivePane(direction: direction)
    }
  }

  private func addTab(inheritSsh: Bool) {
    guard let session = store.activeSession else { return }
    if inheritSsh, let sshCommand = session.sshCommand {
      session.addTab(exec: sshCommand)
    } else {
      session.addTab()
    }
  }

  private func closePane(_ pane: MisttyPane) {
    guard let session = store.activeSession,
      let tab = session.activeTab
    else { return }
    closePaneInTab(pane, tab: tab, session: session)
  }

  private func returnFocusToActivePane() {
    store.activeSession?.activeTab?.activePane?.focusKeyboardInput()
  }

  private func closePaneInTab(_ pane: MisttyPane, tab: MisttyTab, session: MisttySession) {
    tab.closePane(pane)
    if tab.panes.isEmpty {
      session.closeTab(tab)
      if session.tabs.isEmpty {
        store.closeSession(session)
      }
    }
    // A closed tab may have carried a background bell — recompute so the
    // dock badge doesn't linger above the remaining tab count.
    updateDockBadge()
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
      popup.pane.focusKeyboardInput()
    }
  }

  private func handleClosePane() {
    // Dismiss the session manager overlay first; otherwise Cmd-W would
    // close a pane sitting behind the overlay.
    if showingSessionManager {
      showingSessionManager = false
      return
    }
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

  private func handleYankHints() {
    if store.activeSession?.activeTab?.copyModeState?.isHinting == true { return }
    guard let tab = store.activeSession?.activeTab else { return }
    if !tab.isCopyModeActive {
      enterCopyMode()
    }
    guard var state = store.activeSession?.activeTab?.copyModeState else { return }
    let config = MisttyConfig.load()
    state.applyHintEntry(
      action: .copy,
      source: .patterns,
      uppercaseAction: config.copyModeHints.uppercaseAction,
      alphabet: config.copyModeHints.alphabet,
      enteredDirectly: true
    )
    populateHintMatches(&state, source: .patterns)
    store.activeSession?.activeTab?.copyModeState = state
  }

  private func handleCloseTab() {
    if showingSessionManager {
      showingSessionManager = false
      return
    }
    guard let session = store.activeSession,
      let tab = session.activeTab
    else { return }
    session.closeTab(tab)
    if session.tabs.isEmpty {
      store.closeSession(session)
    }
    updateDockBadge()
  }

  private func handleSetTitle(_ notification: Notification) {
    guard let paneID = notification.userInfo?["paneID"] as? Int,
      let raw = notification.userInfo?["title"] as? String,
      let title = TerminalTitle.sanitized(raw)
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

  private func handlePwd(_ notification: Notification) {
    guard let paneID = notification.userInfo?["paneID"] as? Int,
      let pwd = notification.userInfo?["pwd"] as? String,
      !pwd.isEmpty
    else { return }
    let url = URL(fileURLWithPath: pwd, isDirectory: true)
    for session in store.sessions {
      for tab in session.tabs {
        if let pane = tab.panes.first(where: { $0.id == paneID }) {
          pane.currentWorkingDirectory = url
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
    updateDockBadge()
    // Bounce the dock icon once when the bell rings while Mistty is in
    // the background. .informationalRequest bounces once and stops; the
    // call is a no-op when the app is already frontmost so the explicit
    // isActive guard is just for intent.
    if !NSApp.isActive {
      NSApp.requestUserAttention(.informationalRequest)
    }
  }

  /// Set the Dock icon badge to the number of background tabs with an active
  /// bell. Called on ring and on tab-switch (which clears `hasBell` for the
  /// newly-active tab). No-ops when `NSApp` isn't yet available (tests).
  private func updateDockBadge() {
    let count = store.sessions
      .flatMap(\.tabs)
      .filter(\.hasBell)
      .count
    NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
  }

  private func handleCloseSurface(_ notification: Notification) {
    guard let paneID = notification.userInfo?["paneID"] as? Int else { return }
    // Check if this is a popup pane. Always fully close — the `close_on_exit`
    // flag only controls whether ghostty keeps the pane open to show "press
    // any key to close" after the process exits. Once the surface actually
    // closes (process exit OR the user dismisses the wait prompt), the pane
    // is dead and reactivating the popup must spawn a fresh one; otherwise
    // the stale "press any key" output sticks around.
    for session in store.sessions {
      if let popup = session.popups.first(where: { $0.pane.id == paneID }) {
        session.closePopup(popup)
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

      // Cmd+Arrow resize: 5 cells, Cmd+Shift+Arrow resize: 1 cell.
      // Sign matches existing semantics — divider moves right/down on
      // positive cells (pane A grows).
      if event.modifierFlags.contains(.command) {
        let cells = event.modifierFlags.contains(.shift) ? 1 : 5
        switch event.keyCode {
        case 123:  // Left
          resizeActivePaneCells(-cells, along: .horizontal)
          return nil
        case 124:  // Right
          resizeActivePaneCells(cells, along: .horizontal)
          return nil
        case 126:  // Up
          resizeActivePaneCells(-cells, along: .vertical)
          return nil
        case 125:  // Down
          resizeActivePaneCells(cells, along: .vertical)
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
      case 4:  // h — focus left (no swap)
        focusAdjacentPane(.left)
        return nil
      case 38:  // j — focus down (no swap)
        focusAdjacentPane(.down)
        return nil
      case 40:  // k — focus up (no swap)
        focusAdjacentPane(.up)
        return nil
      case 37:  // l — focus right (no swap)
        focusAdjacentPane(.right)
        return nil
      case 6:  // z — zoom toggle; exit window mode once zoom is committed
        toggleZoom()
        store.activeSession?.activeTab?.windowModeState = .inactive
        removeWindowModeMonitor()
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
      case 18, 19, 20, 21, 23:  // 1-5: standard layouts — stay so resize/swap follow-ups work
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

  private func focusAdjacentPane(_ direction: NavigationDirection) {
    guard let tab = store.activeSession?.activeTab,
      let current = tab.activePane,
      let target = tab.layout.adjacentPane(from: current, direction: direction)
    else { return }
    tab.focusPane(target)
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

  /// Resize the split containing the active pane by a row/column count.
  /// Falls back to a ratio-based resize (5% / 1%) if cell metrics aren't
  /// available yet (e.g. before the surface has measured its cell size).
  private func resizeActivePaneCells(_ cells: Int, along direction: SplitDirection) {
    guard let tab = store.activeSession?.activeTab,
      let pane = tab.activePane
    else { return }
    let surfaceView = pane.surfaceView
    let paneBounds = surfaceView.bounds
    guard let metrics = surfaceView.gridMetrics(),
      let unit = tab.layout.unitRect(of: pane),
      unit.width > 0, unit.height > 0,
      paneBounds.width > 0, paneBounds.height > 0
    else {
      // Fallback: approximate ratio per cell (tab has 80 cols / 24 rows)
      let approxCells = CGFloat(abs(cells))
      let ratio: CGFloat = direction == .horizontal ? approxCells / 80.0 : approxCells / 24.0
      let delta: CGFloat = (cells < 0 ? -ratio : ratio)
      tab.layout.resizeSplit(containing: pane, delta: delta, along: direction)
      return
    }
    let tabSize: CGFloat =
      direction == .horizontal ? paneBounds.width / unit.width : paneBounds.height / unit.height
    let cellSize: CGFloat = direction == .horizontal ? metrics.cellWidth : metrics.cellHeight
    tab.layout.resizeSplit(
      containing: pane, cells: cells, along: direction, cellSize: cellSize, tabSize: tabSize)
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
    // Update scrollbar offset synchronously — the async callback will
    // eventually arrive, but we need correct offset immediately for
    // subsequent search coordinate conversion.
    let oldOffset = pane.surfaceView.scrollbarState.offset
    let total = pane.surfaceView.scrollbarState.total
    let len = pane.surfaceView.scrollbarState.len
    // Clamp the same way ghostty does internally: offset can't go below 0
    // (top of scrollback) or above total-len (live area pinned to bottom).
    let maxOffset = total > len ? total - len : 0
    let target = Int64(oldOffset) + Int64(delta)
    let clampedOffset = UInt64(max(0, min(Int64(maxOffset), target)))
    pane.surfaceView.scrollbarState.offset = clampedOffset
    // Adjust the anchor by the *actual* offset change, not the requested
    // delta. Otherwise scrolls that ghostty refused to honor (because we
    // hit the top or bottom of the scrollable area) silently drift the
    // anchor away from its true screen position; on yank, the runaway
    // anchor either passes ghostty's tag-aware pin clamp (selecting too
    // much) or undershoots (selecting too little).
    let actualDelta = Int(clampedOffset) - Int(oldOffset)
    if let anchor = state.anchor {
      state.anchor = (row: anchor.row - actualDelta, col: anchor.col)
    }
    state.scrollGeneration &+= 1
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
          performSearch(&state, direction: state.searchDirection)
          countSearchMatches(&state)
        case .cancelSearch:
          break  // Already handled in state
        case .searchNext:
          performSearch(&state, direction: state.searchDirection)
          countSearchMatches(&state)
        case .searchPrev:
          let reversed: SearchDirection = state.searchDirection == .forward ? .reverse : .forward
          performSearch(&state, direction: reversed)
          countSearchMatches(&state)
        case .scroll(let deltaRows):
          scrollViewport(&state, delta: deltaRows)
          if state.isHinting, let source = state.hint?.source {
            populateHintMatches(&state, source: source)
          }
        case .enterHintMode(let action, let source):
          let cfg = MisttyConfig.load()
          state.applyHintEntry(
            action: action,
            source: source,
            uppercaseAction: cfg.copyModeHints.uppercaseAction,
            alphabet: cfg.copyModeHints.alphabet
          )
        case .requestHintScan:
          let source = state.hint?.source ?? .patterns
          populateHintMatches(&state, source: source)
        case .hintInput:
          break  // typedPrefix already set in state
        case .exitHintMode:
          break  // subMode already reset
        case .copyText(let text):
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        case .openItem(let text):
          if let url = URL(string: text), url.scheme != nil {
            NSWorkspace.shared.open(url)
          } else {
            let proc = Process()
            proc.launchPath = "/usr/bin/open"
            proc.arguments = [text]
            try? proc.run()
          }
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
        tab.focusPane(target)
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

  // MARK: - Alternate Shortcut Monitor
  //
  // SwiftUI Buttons only support one .keyboardShortcut each, so alternate
  // bindings for existing menu actions are handled here to keep the menu
  // uncluttered. Covers:
  //   - Cmd+Up/Down → prev/next tab (primary: Cmd+[ / Cmd+])
  //   - Cmd+Shift+[ / Cmd+Shift+] → prev/next session (primary: Cmd+Shift+Up/Down)
  private func installAltShortcutMonitor() {
    altShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // Arrow keys carry .function and .numericPad bits, which are inside
      // .deviceIndependentFlagsMask and would break a strict `==` match.
      // Restrict comparison to the four user-intent modifiers.
      let meaningful: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
      let flags = event.modifierFlags.intersection(meaningful)

      // Cmd+Up/Down → prev/next tab. Skip when window/copy/session-manager
      // modes own the arrow keys (window mode binds Cmd+arrows to resize).
      if flags == .command {
        let activeTab = store.activeSession?.activeTab
        guard !showingSessionManager,
          activeTab?.isWindowModeActive != true,
          activeTab?.isCopyModeActive != true
        else { return event }

        switch event.keyCode {
        case 126:  // up arrow
          NotificationCenter.default.post(name: .misttyPrevTab, object: nil)
          return nil
        case 125:  // down arrow
          NotificationCenter.default.post(name: .misttyNextTab, object: nil)
          return nil
        default:
          break
        }
      }

      // Cmd+Shift+[/] → prev/next session. Match on keyCode because
      // charactersIgnoringModifiers still applies shift (returning `{`/`}`),
      // and going through `characters` introduces layout-dependent mappings.
      if flags == [.command, .shift] {
        switch event.keyCode {
        case 33:  // left bracket
          NotificationCenter.default.post(name: .misttyPrevSession, object: nil)
          return nil
        case 30:  // right bracket
          NotificationCenter.default.post(name: .misttyNextSession, object: nil)
          return nil
        default:
          break
        }
      }

      // Cmd+Opt+[/] → move session up/down (alt for Cmd+Opt+Up/Down).
      if flags == [.command, .option] {
        switch event.keyCode {
        case 33:  // left bracket
          NotificationCenter.default.post(name: .misttyMoveSessionUp, object: nil)
          return nil
        case 30:  // right bracket
          NotificationCenter.default.post(name: .misttyMoveSessionDown, object: nil)
          return nil
        default:
          break
        }
      }

      return event
    }
  }

  private func removeAltShortcutMonitor() {
    if let monitor = altShortcutMonitor {
      NSEvent.removeMonitor(monitor)
      altShortcutMonitor = nil
    }
  }

  private func installCloseMonitor() {
    closeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] event in
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags.contains(.command),
        event.charactersIgnoringModifiers?.lowercased() == "w"
      else { return event }
      // Local monitors fire for every window in the app. Only intercept when
      // the key window is one of our tracked terminal windows; otherwise let
      // the event flow through so the system can close the focused window
      // (Settings, etc.).
      guard store.isTerminalWindowKey() else {
        DebugLog.shared.log(
          "cmdw",
          "monitor: passing through — not a terminal window"
        )
        return event
      }
      let name: Notification.Name =
        flags.contains(.shift) ? .misttyCloseTab : .misttyClosePane
      DebugLog.shared.log(
        "cmdw", "monitor: consuming, posting \(name.rawValue)"
      )
      NotificationCenter.default.post(name: name, object: nil)
      return nil
    }
  }

  private func removeCloseMonitor() {
    if let monitor = closeMonitor {
      NSEvent.removeMonitor(monitor)
      closeMonitor = nil
    }
  }

  /// Cmd+X overlaps the system Cut command. Whenever any TextField is first
  /// responder (sidebar rename, session-manager search, Settings fields),
  /// SwiftUI disables the "View > Window Mode" menu item and routes Cmd+X to
  /// Cut — so the shortcut appears "lost" (no effect, indicator disappears
  /// from the menu). Mirror the Cmd+W pattern: an app-level local monitor
  /// intercepts Cmd+X before SwiftUI's menu routing runs. Text responders
  /// fall through so Cut still works inside text fields.
  private func installWindowModeShortcutMonitor() {
    windowModeShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [store] event in
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags == .command,
        event.charactersIgnoringModifiers?.lowercased() == "x"
      else { return event }
      guard store.isTerminalWindowKey() else { return event }
      // Any text-editing responder (TextField field editor, NSTextView,
      // search fields) should keep Cmd+X as Cut.
      if let responder = NSApp.keyWindow?.firstResponder, responder is NSText {
        return event
      }
      NotificationCenter.default.post(name: .misttyWindowMode, object: nil)
      return nil
    }
  }

  private func removeWindowModeShortcutMonitor() {
    if let monitor = windowModeShortcutMonitor {
      NSEvent.removeMonitor(monitor)
      windowModeShortcutMonitor = nil
    }
  }

  private func performSearch(_ state: inout CopyModeState, direction: SearchDirection) {
    guard !state.searchQuery.isEmpty,
      let pane = store.activeSession?.activeTab?.activePane,
      let surface = pane.surfaceView.surface
    else { return }

    let scrollbar = pane.surfaceView.scrollbarState
    let totalRows = Int(scrollbar.total)
    let viewportOffset = Int(scrollbar.offset)
    let cols = Int(ghostty_surface_size(surface).columns)
    guard totalRows > 0 else { return }

    let cursorScreenRow = state.cursorRow + viewportOffset
    let isForward = direction == .forward

    // Search all rows, starting from the current row.
    // On the current row, only consider matches AFTER (forward) or BEFORE (reverse) the cursor.
    for i in 0...totalRows {
      let screenRow: Int
      if isForward {
        screenRow = (cursorScreenRow + i) % totalRows
      } else {
        screenRow = (cursorScreenRow - i + totalRows) % totalRows
      }

      guard let line = readLineByScreenRow(screenRow) else { continue }

      // Find the right match on this line
      let matchCol: Int?
      if i == 0 {
        // Current row: find the next/prev match relative to cursor column
        matchCol = findMatchOnLine(
          line, query: state.searchQuery, cursorCol: state.cursorCol, forward: isForward)
      } else {
        // Other rows: find the first (forward) or last (reverse) match
        matchCol = findMatchOnLine(
          line, query: state.searchQuery, cursorCol: isForward ? -1 : Int.max, forward: isForward)
      }

      if let col = matchCol {
        // Scroll to make the match visible — center it in viewport
        let viewportRows = Int(scrollbar.len)
        let targetOffset = max(0, min(screenRow - viewportRows / 2, totalRows - viewportRows))
        let actionStr = "scroll_to_row:\(targetOffset)"
        _ = ghostty_surface_binding_action(surface, actionStr, UInt(actionStr.utf8.count))

        // Update scrollbar state synchronously — the async callback will
        // eventually arrive with the same value, but we need it now for
        // subsequent searches (n/N) to compute correct screen coordinates.
        pane.surfaceView.scrollbarState.offset = UInt64(targetOffset)

        state.cursorRow = screenRow - targetOffset
        state.cursorCol = min(col, cols - 1)
        state.desiredCol = nil
        return
      }
    }
  }

  /// Find the next (forward) or previous (reverse) match on a line relative to cursorCol.
  /// Returns the column of the match, or nil if none found.
  private func findMatchOnLine(
    _ line: String, query: String, cursorCol: Int, forward: Bool
  ) -> Int? {
    var bestCol: Int?
    var searchStart = line.startIndex
    while let range = line.range(of: query, options: .caseInsensitive, range: searchStart..<line.endIndex) {
      let col = line.distance(from: line.startIndex, to: range.lowerBound)
      if forward {
        // Find first match with col > cursorCol
        if col > cursorCol {
          return col
        }
      } else {
        // Find last match with col < cursorCol
        if col < cursorCol {
          bestCol = col
        }
      }
      searchStart = range.upperBound
    }
    return bestCol
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
      guard let line = readLineByScreenRow(row) else { continue }
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

  /// Read a line by screen row, preferring VIEWPORT reading when the row is visible.
  /// This ensures consistency with the highlight overlay (which uses VIEWPORT).
  private func readLineByScreenRow(_ screenRow: Int) -> String? {
    guard let pane = store.activeSession?.activeTab?.activePane else { return nil }
    let scrollbar = pane.surfaceView.scrollbarState
    let viewportRow = screenRow - Int(scrollbar.offset)
    if viewportRow >= 0 && viewportRow < Int(scrollbar.len) {
      return readTerminalLine(row: viewportRow)
    }
    return readScreenLine(row: screenRow)
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

  private func scanViewportForHints(source: HintSource) -> [HintMatch] {
    guard let state = store.activeSession?.activeTab?.copyModeState else { return [] }
    var lines: [String] = []
    for row in 0..<state.rows {
      lines.append(readTerminalLine(row: row) ?? "")
    }
    return HintDetector.detect(lines: lines, source: source)
  }

  private func populateHintMatches(_ state: inout CopyModeState, source: HintSource) {
    let matches = scanViewportForHints(source: source)
    state.setHintMatches(matches)
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
      let (top, bottom) = CopyModeYank.normalize(
        anchor: (row: anchor.row + offset, col: anchor.col),
        cursor: (row: state.cursorRow + offset, col: state.cursorCol)
      )
      textToCopy = readGhosttyText(
        surface: surface,
        startRow: top.row, startCol: top.col,
        endRow: bottom.row, endCol: bottom.col,
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
