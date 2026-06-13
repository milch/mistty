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

  /// Shared dispatch scaffold. Wraps the reply for @MainActor capture,
  /// runs `body` on the main actor, encodes its return value (nil →
  /// empty `{}` success), and routes thrown errors to the reply's error
  /// slot. Every IPC method used to hand-roll this. A returned `Data`
  /// passes through unchanged — for bodies with a bespoke encoder.
  private func onMain(
    _ reply: @escaping (Data?, Error?) -> Void,
    _ body: @escaping @MainActor () throws -> (any Encodable)?
  ) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      do {
        if let value = try body() {
          if let data = value as? Data {
            reply(data, nil)
          } else {
            reply(self.encode(value), nil)
          }
        } else {
          reply(Data("{}".utf8), nil)
        }
      } catch {
        reply(nil, error)
      }
    }
  }

  /// Unwrap an entity lookup or throw the matching IPC error.
  private func require<T>(
    _ value: T?, _ code: MisttyIPC.ErrorCode, _ message: String
  ) throws -> T {
    guard let value else { throw MisttyIPC.error(code, message) }
    return value
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
    name: String?, directory: String?, exec: String?, windowID: Int?,
    reply: @escaping (Data?, Error?) -> Void
  ) {
    onMain(reply) {
      let target = try self.require(
        self.windowsStore.resolveTargetWindow(explicit: windowID), .invalidArgument,
        "no focused window; pass --window <id> or focus a terminal window first")
      let dir = directory.map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
      // When --name is supplied, promote it to customName so it wins over
      // the cwd-derived sidebarLabel (which would otherwise display the
      // directory's lastPathComponent — e.g. the user's username when
      // dir == ~). When --name is omitted, leave customName nil so the
      // sidebarLabel falls through to its usual cwd basename.
      let session = target.createSession(
        name: name ?? "Default", directory: dir, exec: exec, customName: name)
      return self.sessionResponse(session, windowID: target.id)
    }
  }

  func listSessions(reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      self.windowsStore.windows.flatMap { window in
        window.sessions.map { self.sessionResponse($0, windowID: window.id) }
      }
    }
  }

  func getSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.session(byId: id), .entityNotFound, "Session \(id) not found")
      return self.sessionResponse(resolved.session, windowID: resolved.window.id)
    }
  }

  func closeSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.session(byId: id), .entityNotFound, "Session \(id) not found")
      resolved.window.closeSession(resolved.session)
      return nil
    }
  }

  func reparentSession(
    id: Int, directory: String, reply: @escaping (Data?, Error?) -> Void
  ) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.session(byId: id), .entityNotFound, "Session \(id) not found")
      let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
        isDir.boolValue
      else {
        throw MisttyIPC.error(.invalidArgument, "Directory does not exist: \(url.path)")
      }
      resolved.session.setDirectory(url)
      return self.sessionResponse(resolved.session, windowID: resolved.window.id)
    }
  }

  // MARK: - Tabs

  func createTab(
    sessionId: Int, name: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void
  ) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.session(byId: sessionId), .entityNotFound,
        "Session \(sessionId) not found")
      resolved.session.addTab(exec: exec)
      let tab = try self.require(
        resolved.session.tabs.last, .operationFailed, "Failed to create tab")
      if let name { tab.customTitle = name }
      return self.tabResponse(tab, windowID: resolved.window.id)
    }
  }

  func listTabs(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.session(byId: sessionId), .entityNotFound,
        "Session \(sessionId) not found")
      return resolved.session.tabs.map { self.tabResponse($0, windowID: resolved.window.id) }
    }
  }

  func getTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.tab(byId: id), .entityNotFound, "Tab \(id) not found")
      return self.tabResponse(resolved.tab, windowID: resolved.window.id)
    }
  }

  func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.tab(byId: id), .entityNotFound, "Tab \(id) not found")
      resolved.session.closeTab(resolved.tab)
      return nil
    }
  }

  func renameTab(id: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.tab(byId: id), .entityNotFound, "Tab \(id) not found")
      resolved.tab.customTitle = name
      return self.tabResponse(resolved.tab, windowID: resolved.window.id)
    }
  }

  // MARK: - Panes

  func createPane(tabId: Int, direction: String?, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.tab(byId: tabId), .entityNotFound, "Tab \(tabId) not found")
      let splitDir: SplitDirection = direction == "horizontal" ? .horizontal : .vertical
      resolved.tab.splitActivePane(direction: splitDir)
      let newPane = try self.require(
        resolved.tab.panes.last, .operationFailed, "Failed to create pane")
      return self.paneResponse(newPane, windowID: resolved.window.id)
    }
  }

  func listPanes(tabId: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.tab(byId: tabId), .entityNotFound, "Tab \(tabId) not found")
      return resolved.tab.panes.map { self.paneResponse($0, windowID: resolved.window.id) }
    }
  }

  func getPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.pane(byId: id), .entityNotFound, "Pane \(id) not found")
      return self.paneResponse(resolved.pane, windowID: resolved.window.id)
    }
  }

  func closePane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.pane(byId: id), .entityNotFound, "Pane \(id) not found")
      resolved.tab.closePane(resolved.pane)
      return nil
    }
  }

  func focusPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.pane(byId: id), .entityNotFound, "Pane \(id) not found")
      resolved.window.activeSession = resolved.session
      resolved.session.activeTab = resolved.tab
      resolved.tab.focusPane(resolved.pane)
      return self.paneResponse(resolved.pane, windowID: resolved.window.id)
    }
  }

  func focusPaneByDirection(
    direction: String, sessionId: Int, reply: @escaping (Data?, Error?) -> Void
  ) {
    onMain(reply) {
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
      let resolvedSession = try self.require(session, .entityNotFound, "Session not found")
      guard let tab = resolvedSession.activeTab,
        let pane = tab.activePane
      else {
        throw MisttyIPC.error(.entityNotFound, "No active pane")
      }

      let navDirection: NavigationDirection
      switch direction {
      case "left": navDirection = .left
      case "right": navDirection = .right
      case "up": navDirection = .up
      case "down": navDirection = .down
      default:
        throw MisttyIPC.error(
          .invalidArgument, "Invalid direction: \(direction). Use left, right, up, or down")
      }

      guard let targetID = tab.layout.adjacentPaneID(from: pane, direction: navDirection),
        let target = tab.pane(byID: targetID)
      else {
        throw MisttyIPC.error(.operationFailed, "No pane in direction \(direction)")
      }

      tab.focusPane(target)
      return self.paneResponse(target, windowID: owningWindowID)
    }
  }

  func resizePane(id: Int, direction: String, amount: Int, reply: @escaping (Data?, Error?) -> Void)
  {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.pane(byId: id), .entityNotFound, "Pane \(id) not found")
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
        throw MisttyIPC.error(
          .invalidArgument, "Invalid direction: \(direction). Use left, right, up, or down")
      }
      resolved.tab.layout.resizeSplit(containing: resolved.pane, delta: delta * sign, along: splitDir)
      return nil
    }
  }

  func activePane(reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      guard let activeWin = self.windowsStore.activeWindow,
        let pane = activeWin.activeSession?.activeTab?.activePane
      else {
        throw MisttyIPC.error(.entityNotFound, "No active pane")
      }
      return self.paneResponse(pane, windowID: activeWin.id)
    }
  }

  func sendKeys(paneId: Int, keys: String, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let targetPane: MisttyPane?
      if paneId == 0 {
        targetPane = self.windowsStore.activeWindow?.activeSession?.activeTab?.activePane
      } else {
        targetPane = self.windowsStore.pane(byId: paneId)?.pane
      }
      let pane = try self.require(targetPane, .entityNotFound, "Pane \(paneId) not found")
      let surface = try self.require(
        pane.surfaceView.surface, .operationFailed, "Pane has no active surface")
      keys.withCString { ptr in
        ghostty_surface_text(surface, ptr, UInt(keys.utf8.count))
      }
      return nil
    }
  }

  func runCommand(paneId: Int, command: String, reply: @escaping (Data?, Error?) -> Void) {
    sendKeys(paneId: paneId, keys: command + "\n", reply: reply)
  }

  func getText(paneId: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let targetPane: MisttyPane?
      if paneId == 0 {
        targetPane = self.windowsStore.activeWindow?.activeSession?.activeTab?.activePane
      } else {
        targetPane = self.windowsStore.pane(byId: paneId)?.pane
      }
      let pane = try self.require(targetPane, .entityNotFound, "Pane \(paneId) not found")
      let surface = try self.require(
        pane.surfaceView.surface, .operationFailed, "Pane has no active surface")

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
        throw MisttyIPC.error(.operationFailed, "Failed to read text from surface")
      }
      defer { ghostty_surface_free_text(surface, &text) }

      let content: String
      if let ptr = text.text {
        content = String(cString: ptr)
      } else {
        content = ""
      }

      return GetTextResponse(text: content)
    }
  }

  // MARK: - Windows

  func createWindow(reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let action = try self.require(
        self.windowsStore.openWindowAction, .invalidArgument,
        "IPC not yet ready; first window must mount before createWindow can spawn additional windows")
      let id = self.windowsStore.prepareWindowForIPCCreate()
      action(id: "terminal")
      return WindowResponse(id: id, sessionCount: 0)
    }
  }

  func listWindows(reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      self.windowsStore.trackedNSWindows.map { tracked in
        let windowState = self.windowsStore.window(byId: tracked.id)
        let sessionCount = windowState?.sessions.count ?? 0
        return WindowResponse(id: tracked.id, sessionCount: sessionCount)
      }
    }
  }

  func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let tracked = try self.require(
        self.windowsStore.trackedNSWindow(byId: id), .entityNotFound, "Window \(id) not found")
      let windowState = self.windowsStore.window(byId: tracked.id)
      let sessionCount = windowState?.sessions.count ?? 0
      return WindowResponse(id: tracked.id, sessionCount: sessionCount)
    }
  }

  func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let tracked = try self.require(
        self.windowsStore.trackedNSWindow(byId: id), .entityNotFound, "Window \(id) not found")
      tracked.window?.close()
      if let window = tracked.window {
        self.windowsStore.unregisterNSWindow(window)
      }
      return nil
    }
  }

  func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let tracked = try self.require(
        self.windowsStore.trackedNSWindow(byId: id), .entityNotFound, "Window \(id) not found")
      tracked.window?.makeKeyAndOrderFront(nil)
      return nil
    }
  }

  // MARK: - Popups

  func openPopup(
    sessionId: Int, name: String, exec: String, width: Double, height: Double, closeOnExit: Bool,
    reply: @escaping (Data?, Error?) -> Void
  ) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.session(byId: sessionId), .entityNotFound,
        "Session \(sessionId) not found")
      let definition = PopupDefinition(
        name: name, command: exec, width: width, height: height, closeOnExit: closeOnExit)
      resolved.session.openPopup(definition: definition)
      let popup = try self.require(
        resolved.session.activePopup, .operationFailed, "Failed to create popup")
      return self.popupResponse(popup, windowID: resolved.window.id)
    }
  }

  func closePopup(popupId: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.popup(byId: popupId), .entityNotFound, "Popup \(popupId) not found")
      resolved.session.closePopup(resolved.popup)
      return nil
    }
  }

  func togglePopup(sessionId: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.session(byId: sessionId), .entityNotFound,
        "Session \(sessionId) not found")
      let config = MisttyConfig.load()
      let definition = try self.require(
        config.popups.first(where: { $0.name == name }), .entityNotFound,
        "Popup definition '\(name)' not found in config")
      resolved.session.togglePopup(definition: definition)
      guard let popup = resolved.session.popups.first(where: { $0.definition.name == name })
      else { return nil }
      return self.popupResponse(popup, windowID: resolved.window.id)
    }
  }

  func listPopups(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let resolved = try self.require(
        self.windowsStore.session(byId: sessionId), .entityNotFound,
        "Session \(sessionId) not found")
      return resolved.session.popups.map { self.popupResponse($0, windowID: resolved.window.id) }
    }
  }

  // MARK: - Meta

  func getVersion(reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let info = Bundle.main.infoDictionary ?? [:]
      let version = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
      let bundleID = (info["CFBundleIdentifier"] as? String) ?? "unknown"
      let response = VersionResponse(version: version, bundleIdentifier: bundleID)
      // Pre-encoded so an encode failure still surfaces as an error reply.
      return try JSONEncoder().encode(response)
    }
  }

  // MARK: - Config

  func reloadConfig(reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      do {
        try MisttyConfig.reload()
      } catch {
        throw MisttyIPC.error(
          .operationFailed,
          "Could not reload config: \(describeTOMLParseError(error))")
      }
      return nil
    }
  }

  // MARK: - Debug

  func getStateSnapshot(reply: @escaping (Data?, Error?) -> Void) {
    onMain(reply) {
      let snapshot = self.windowsStore.takeSnapshot()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      // Pre-encoded Data passes through onMain unchanged (bespoke encoder).
      return try encoder.encode(snapshot)
    }
  }
}
