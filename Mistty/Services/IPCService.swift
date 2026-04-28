import AppKit
import Foundation
import GhosttyKit
import MisttyShared

/// Wraps a non-Sendable reply closure so it can be captured by a @MainActor Task.
/// Reply handlers are thread-safe by design — they just aren't annotated as @Sendable.
private struct Reply: @unchecked Sendable {
  let handler: (Data?, Error?) -> Void

  func callAsFunction(_ data: Data?, _ error: Error?) {
    handler(data, error)
  }
}

final class MisttyIPCService: MisttyServiceProtocol, Sendable {
  private let windowsStore: WindowsStore

  init(windowsStore: WindowsStore) {
    self.windowsStore = windowsStore
  }

  // MARK: - Helpers

  private func encode<T: Encodable>(_ value: T) -> Data? {
    try? JSONEncoder().encode(value)
  }

  private func notImplemented(_ reply: @escaping (Data?, Error?) -> Void) {
    reply(nil, MisttyIPC.error(.operationFailed, "Not implemented"))
  }

  @MainActor private func sessionResponse(_ session: MisttySession, windowID: Int) -> SessionResponse {
    SessionResponse(
      id: session.id,
      window: windowID,
      name: session.name,
      directory: session.directory.path,
      tabCount: session.tabs.count,
      tabIds: session.tabs.map(\.id)
    )
  }

  @MainActor private func tabResponse(_ tab: MisttyTab, windowID: Int) -> TabResponse {
    TabResponse(
      id: tab.id,
      window: windowID,
      title: tab.displayTitle,
      paneCount: tab.panes.count,
      paneIds: tab.panes.map(\.id)
    )
  }

  @MainActor private func paneResponse(_ pane: MisttyPane, windowID: Int) -> PaneResponse {
    PaneResponse(
      id: pane.id,
      window: windowID,
      directory: pane.directory?.path
    )
  }

  @MainActor private func popupResponse(_ popup: PopupState, windowID: Int) -> PopupResponse {
    PopupResponse(
      id: popup.id,
      window: windowID,
      name: popup.definition.name,
      command: popup.definition.command,
      isVisible: popup.isVisible,
      paneId: popup.pane.id
    )
  }

  // MARK: - Sessions

  func createSession(
    name: String, directory: String?, exec: String?, windowID: Int?,
    reply: @escaping (Data?, Error?) -> Void
  ) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let target = self.windowsStore.resolveTargetWindow(explicit: windowID) else {
        reply(nil, MisttyIPC.error(.invalidArgument,
          "no focused window; pass --window <id> or focus a terminal window first"))
        return
      }
      let dir = directory.map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
      let session = target.createSession(name: name, directory: dir, exec: exec)
      reply(self.encode(self.sessionResponse(session, windowID: target.id)), nil)
    }
  }

  func listSessions(reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      let responses = self.windowsStore.windows.flatMap { window in
        window.sessions.map { self.sessionResponse($0, windowID: window.id) }
      }
      reply(self.encode(responses), nil)
    }
  }

  func getSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.session(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Session \(id) not found"))
        return
      }
      reply(self.encode(self.sessionResponse(resolved.session, windowID: resolved.window.id)), nil)
    }
  }

  func closeSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.session(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Session \(id) not found"))
        return
      }
      resolved.window.closeSession(resolved.session)
      reply(self.encode([String: String]()), nil)
    }
  }

  // MARK: - Tabs

  func createTab(
    sessionId: Int, name: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void
  ) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.session(byId: sessionId) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
        return
      }
      resolved.session.addTab(exec: exec)
      guard let tab = resolved.session.tabs.last else {
        reply(nil, MisttyIPC.error(.operationFailed, "Failed to create tab"))
        return
      }
      if let name { tab.customTitle = name }
      reply(self.encode(self.tabResponse(tab, windowID: resolved.window.id)), nil)
    }
  }

  func listTabs(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.session(byId: sessionId) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
        return
      }
      let responses = resolved.session.tabs.map { self.tabResponse($0, windowID: resolved.window.id) }
      reply(self.encode(responses), nil)
    }
  }

  func getTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.tab(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(id) not found"))
        return
      }
      reply(self.encode(self.tabResponse(resolved.tab, windowID: resolved.window.id)), nil)
    }
  }

  func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.tab(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(id) not found"))
        return
      }
      resolved.session.closeTab(resolved.tab)
      reply(self.encode([String: String]()), nil)
    }
  }

  func renameTab(id: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.tab(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(id) not found"))
        return
      }
      resolved.tab.customTitle = name
      reply(self.encode(self.tabResponse(resolved.tab, windowID: resolved.window.id)), nil)
    }
  }

  // MARK: - Panes

  func createPane(tabId: Int, direction: String?, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.tab(byId: tabId) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(tabId) not found"))
        return
      }
      let splitDir: SplitDirection = direction == "horizontal" ? .horizontal : .vertical
      resolved.tab.splitActivePane(direction: splitDir)
      guard let newPane = resolved.tab.panes.last else {
        reply(nil, MisttyIPC.error(.operationFailed, "Failed to create pane"))
        return
      }
      reply(self.encode(self.paneResponse(newPane, windowID: resolved.window.id)), nil)
    }
  }

  func listPanes(tabId: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.tab(byId: tabId) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(tabId) not found"))
        return
      }
      let responses = resolved.tab.panes.map { self.paneResponse($0, windowID: resolved.window.id) }
      reply(self.encode(responses), nil)
    }
  }

  func getPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.pane(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(id) not found"))
        return
      }
      reply(self.encode(self.paneResponse(resolved.pane, windowID: resolved.window.id)), nil)
    }
  }

  func closePane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.pane(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(id) not found"))
        return
      }
      resolved.tab.closePane(resolved.pane)
      reply(self.encode([String: String]()), nil)
    }
  }

  func focusPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.pane(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(id) not found"))
        return
      }
      resolved.window.activeSession = resolved.session
      resolved.session.activeTab = resolved.tab
      resolved.tab.focusPane(resolved.pane)
      reply(self.encode(self.paneResponse(resolved.pane, windowID: resolved.window.id)), nil)
    }
  }

  func focusPaneByDirection(
    direction: String, sessionId: Int, reply: @escaping (Data?, Error?) -> Void
  ) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      let session: MisttySession?
      let owningWindowID: Int
      if sessionId == 0 {
        let activeWin = self.windowsStore.activeWindow
        session = activeWin?.activeSession
        owningWindowID = activeWin?.id ?? 0
      } else {
        let resolved = self.windowsStore.session(byId: sessionId)
        session = resolved?.session
        owningWindowID = resolved?.window.id ?? 0
      }
      guard let session else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Session not found"))
        return
      }
      guard let tab = session.activeTab,
        let pane = tab.activePane
      else {
        reply(nil, MisttyIPC.error(.entityNotFound, "No active pane"))
        return
      }

      let navDirection: NavigationDirection
      switch direction {
      case "left": navDirection = .left
      case "right": navDirection = .right
      case "up": navDirection = .up
      case "down": navDirection = .down
      default:
        reply(
          nil,
          MisttyIPC.error(
            .invalidArgument, "Invalid direction: \(direction). Use left, right, up, or down"))
        return
      }

      guard let target = tab.layout.adjacentPane(from: pane, direction: navDirection) else {
        reply(nil, MisttyIPC.error(.operationFailed, "No pane in direction \(direction)"))
        return
      }

      tab.focusPane(target)
      reply(self.encode(self.paneResponse(target, windowID: owningWindowID)), nil)
    }
  }

  func resizePane(id: Int, direction: String, amount: Int, reply: @escaping (Data?, Error?) -> Void)
  {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.pane(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(id) not found"))
        return
      }
      let delta = CGFloat(amount) / 100.0
      let splitDir: SplitDirection?
      let sign: CGFloat
      switch direction {
      case "left":
        splitDir = .horizontal
        sign = -1.0
      case "right":
        splitDir = .horizontal
        sign = 1.0
      case "up":
        splitDir = .vertical
        sign = -1.0
      case "down":
        splitDir = .vertical
        sign = 1.0
      default:
        reply(
          nil,
          MisttyIPC.error(
            .invalidArgument, "Invalid direction: \(direction). Use left, right, up, or down"))
        return
      }
      resolved.tab.layout.resizeSplit(containing: resolved.pane, delta: delta * sign, along: splitDir)
      reply(Data("{}".utf8), nil)
    }
  }

  func activePane(reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let activeWin = self.windowsStore.activeWindow,
            let pane = activeWin.activeSession?.activeTab?.activePane else {
        reply(nil, MisttyIPC.error(.entityNotFound, "No active pane"))
        return
      }
      reply(self.encode(self.paneResponse(pane, windowID: activeWin.id)), nil)
    }
  }

  func sendKeys(paneId: Int, keys: String, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor [windowsStore] in
      let targetPane: MisttyPane?
      if paneId == 0 {
        targetPane = windowsStore.activeWindow?.activeSession?.activeTab?.activePane
      } else {
        targetPane = windowsStore.pane(byId: paneId)?.pane
      }
      guard let pane = targetPane else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(paneId) not found"))
        return
      }
      let view = pane.surfaceView
      guard let surface = view.surface else {
        reply(nil, MisttyIPC.error(.operationFailed, "Pane has no active surface"))
        return
      }
      keys.withCString { ptr in
        ghostty_surface_text(surface, ptr, UInt(keys.utf8.count))
      }
      reply(self.encode([String: String]()), nil)
    }
  }

  func runCommand(paneId: Int, command: String, reply: @escaping (Data?, Error?) -> Void) {
    sendKeys(paneId: paneId, keys: command + "\n", reply: reply)
  }

  func getText(paneId: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      let targetPane: MisttyPane?
      if paneId == 0 {
        targetPane = self.windowsStore.activeWindow?.activeSession?.activeTab?.activePane
      } else {
        targetPane = self.windowsStore.pane(byId: paneId)?.pane
      }
      guard let pane = targetPane else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(paneId) not found"))
        return
      }
      guard let surface = pane.surfaceView.surface else {
        reply(nil, MisttyIPC.error(.operationFailed, "Pane has no active surface"))
        return
      }

      let size = ghostty_surface_size(surface)
      let rows = Int(size.rows)
      let cols = Int(size.columns)

      // Read the entire visible viewport as a single selection
      var sel = ghostty_selection_s()
      sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
      sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
      sel.top_left.x = 0
      sel.top_left.y = 0
      sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
      sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
      sel.bottom_right.x = UInt32(cols - 1)
      sel.bottom_right.y = UInt32(rows - 1)
      sel.rectangle = false

      var text = ghostty_text_s()
      guard ghostty_surface_read_text(surface, sel, &text) else {
        reply(nil, MisttyIPC.error(.operationFailed, "Failed to read text from surface"))
        return
      }
      defer { ghostty_surface_free_text(surface, &text) }

      let content: String
      if let ptr = text.text {
        content = String(cString: ptr)
      } else {
        content = ""
      }

      reply(self.encode(GetTextResponse(text: content)), nil)
    }
  }

  // MARK: - Windows

  func createWindow(reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let action = self.windowsStore.openWindowAction else {
        reply(nil, MisttyIPC.error(.invalidArgument,
          "IPC not yet ready; first window must mount before createWindow can spawn additional windows"))
        return
      }
      let id = self.windowsStore.prepareWindowForIPCCreate()
      action(id: "terminal")
      let response = WindowResponse(id: id, sessionCount: 0)
      reply(self.encode(response), nil)
    }
  }

  func listWindows(reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      let responses = self.windowsStore.trackedNSWindows.map { tracked in
        let windowState = self.windowsStore.window(byId: tracked.id)
        let sessionCount = windowState?.sessions.count ?? 0
        return WindowResponse(id: tracked.id, sessionCount: sessionCount)
      }
      reply(self.encode(responses), nil)
    }
  }

  func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let tracked = self.windowsStore.trackedNSWindow(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Window \(id) not found"))
        return
      }
      let windowState = self.windowsStore.window(byId: tracked.id)
      let sessionCount = windowState?.sessions.count ?? 0
      reply(self.encode(WindowResponse(id: tracked.id, sessionCount: sessionCount)), nil)
    }
  }

  func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let tracked = self.windowsStore.trackedNSWindow(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Window \(id) not found"))
        return
      }
      tracked.window?.close()
      if let window = tracked.window {
        self.windowsStore.unregisterNSWindow(window)
      }
      reply(self.encode([String: String]()), nil)
    }
  }

  func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let tracked = self.windowsStore.trackedNSWindow(byId: id) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Window \(id) not found"))
        return
      }
      tracked.window?.makeKeyAndOrderFront(nil)
      reply(self.encode([String: String]()), nil)
    }
  }

  // MARK: - Popups

  func openPopup(
    sessionId: Int, name: String, exec: String, width: Double, height: Double, closeOnExit: Bool,
    reply: @escaping (Data?, Error?) -> Void
  ) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.session(byId: sessionId) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
        return
      }
      let definition = PopupDefinition(
        name: name, command: exec, width: width, height: height, closeOnExit: closeOnExit)
      resolved.session.openPopup(definition: definition)
      guard let popup = resolved.session.activePopup else {
        reply(nil, MisttyIPC.error(.operationFailed, "Failed to create popup"))
        return
      }
      reply(self.encode(self.popupResponse(popup, windowID: resolved.window.id)), nil)
    }
  }

  func closePopup(popupId: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.popup(byId: popupId) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Popup \(popupId) not found"))
        return
      }
      resolved.session.closePopup(resolved.popup)
      reply(self.encode([String: String]()), nil)
    }
  }

  func togglePopup(sessionId: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.session(byId: sessionId) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
        return
      }
      let config = MisttyConfig.load()
      guard let definition = config.popups.first(where: { $0.name == name }) else {
        reply(
          nil, MisttyIPC.error(.entityNotFound, "Popup definition '\(name)' not found in config"))
        return
      }
      resolved.session.togglePopup(definition: definition)
      if let popup = resolved.session.popups.first(where: { $0.definition.name == name }) {
        reply(self.encode(self.popupResponse(popup, windowID: resolved.window.id)), nil)
      } else {
        reply(self.encode([String: String]()), nil)
      }
    }
  }

  func listPopups(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let resolved = self.windowsStore.session(byId: sessionId) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
        return
      }
      let responses = resolved.session.popups.map { self.popupResponse($0, windowID: resolved.window.id) }
      reply(self.encode(responses), nil)
    }
  }

  // MARK: - Meta

  func getVersion(reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    let info = Bundle.main.infoDictionary ?? [:]
    let version = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
    let bundleID = (info["CFBundleIdentifier"] as? String) ?? "unknown"
    let response = VersionResponse(version: version, bundleIdentifier: bundleID)
    do {
      reply(try JSONEncoder().encode(response), nil)
    } catch {
      reply(nil, error)
    }
  }

  // MARK: - Config

  func reloadConfig(reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      do {
        try MisttyConfig.reload()
        reply(Data("{}".utf8), nil)
      } catch {
        reply(
          nil,
          MisttyIPC.error(
            .operationFailed,
            "Could not reload config: \(describeTOMLParseError(error))"))
      }
    }
  }

  // MARK: - Debug

  func getStateSnapshot(reply: @escaping (Data?, Error?) -> Void) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      let snapshot = self.windowsStore.takeSnapshot()
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        reply(data, nil)
      } catch {
        reply(nil, error)
      }
    }
  }
}
