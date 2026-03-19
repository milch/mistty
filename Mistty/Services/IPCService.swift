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
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    // MARK: - Helpers

    private func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private func notImplemented(_ reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyIPC.error(.operationFailed, "Not implemented"))
    }

    @MainActor private func sessionResponse(_ session: MisttySession) -> SessionResponse {
        SessionResponse(
            id: session.id,
            name: session.name,
            directory: session.directory.path,
            tabCount: session.tabs.count,
            tabIds: session.tabs.map(\.id)
        )
    }

    @MainActor private func tabResponse(_ tab: MisttyTab) -> TabResponse {
        TabResponse(
            id: tab.id,
            title: tab.displayTitle,
            paneCount: tab.panes.count,
            paneIds: tab.panes.map(\.id)
        )
    }

    @MainActor private func paneResponse(_ pane: MisttyPane) -> PaneResponse {
        PaneResponse(
            id: pane.id,
            directory: pane.directory?.path
        )
    }

    @MainActor private func popupResponse(_ popup: PopupState) -> PopupResponse {
        PopupResponse(
            id: popup.id,
            name: popup.definition.name,
            command: popup.definition.command,
            isVisible: popup.isVisible,
            paneId: popup.pane.id
        )
    }

    // MARK: - Sessions

    func createSession(name: String, directory: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            let dir = URL(fileURLWithPath: directory ?? FileManager.default.homeDirectoryForCurrentUser.path)
            let session = self.store.createSession(name: name, directory: dir, exec: exec)
            reply(self.encode(self.sessionResponse(session)), nil)
        }
    }

    func listSessions(reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            let responses = self.store.sessions.map { self.sessionResponse($0) }
            reply(self.encode(responses), nil)
        }
    }

    func getSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let session = self.store.session(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Session \(id) not found"))
                return
            }
            reply(self.encode(self.sessionResponse(session)), nil)
        }
    }

    func closeSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let session = self.store.session(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Session \(id) not found"))
                return
            }
            self.store.closeSession(session)
            reply(self.encode([String: String]()), nil)
        }
    }

    // MARK: - Tabs

    func createTab(sessionId: Int, name: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let session = self.store.session(byId: sessionId) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
                return
            }
            session.addTab(exec: exec)
            guard let tab = session.tabs.last else {
                reply(nil, MisttyIPC.error(.operationFailed, "Failed to create tab"))
                return
            }
            if let name { tab.customTitle = name }
            reply(self.encode(self.tabResponse(tab)), nil)
        }
    }

    func listTabs(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let session = self.store.session(byId: sessionId) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
                return
            }
            let responses = session.tabs.map { self.tabResponse($0) }
            reply(self.encode(responses), nil)
        }
    }

    func getTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, tab) = self.store.tab(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(id) not found"))
                return
            }
            reply(self.encode(self.tabResponse(tab)), nil)
        }
    }

    func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (session, tab) = self.store.tab(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(id) not found"))
                return
            }
            session.closeTab(tab)
            reply(self.encode([String: String]()), nil)
        }
    }

    func renameTab(id: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, tab) = self.store.tab(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(id) not found"))
                return
            }
            tab.customTitle = name
            reply(self.encode(self.tabResponse(tab)), nil)
        }
    }

    // MARK: - Panes

    func createPane(tabId: Int, direction: String?, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, tab) = self.store.tab(byId: tabId) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(tabId) not found"))
                return
            }
            let splitDir: SplitDirection = direction == "horizontal" ? .horizontal : .vertical
            tab.splitActivePane(direction: splitDir)
            guard let newPane = tab.panes.last else {
                reply(nil, MisttyIPC.error(.operationFailed, "Failed to create pane"))
                return
            }
            reply(self.encode(self.paneResponse(newPane)), nil)
        }
    }

    func listPanes(tabId: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, tab) = self.store.tab(byId: tabId) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Tab \(tabId) not found"))
                return
            }
            let responses = tab.panes.map { self.paneResponse($0) }
            reply(self.encode(responses), nil)
        }
    }

    func getPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, _, pane) = self.store.pane(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(id) not found"))
                return
            }
            reply(self.encode(self.paneResponse(pane)), nil)
        }
    }

    func closePane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, tab, pane) = self.store.pane(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(id) not found"))
                return
            }
            tab.closePane(pane)
            reply(self.encode([String: String]()), nil)
        }
    }

    func focusPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (session, tab, pane) = self.store.pane(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(id) not found"))
                return
            }
            self.store.activeSession = session
            session.activeTab = tab
            tab.activePane = pane
            reply(self.encode(self.paneResponse(pane)), nil)
        }
    }

    func focusPaneByDirection(direction: String, sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            let session: MisttySession?
            if sessionId == 0 {
                session = self.store.activeSession
            } else {
                session = self.store.session(byId: sessionId)
            }
            guard let session else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Session not found"))
                return
            }
            guard let tab = session.activeTab,
                  let pane = tab.activePane else {
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
                reply(nil, MisttyIPC.error(.invalidArgument, "Invalid direction: \(direction). Use left, right, up, or down"))
                return
            }

            guard let target = tab.layout.adjacentPane(from: pane, direction: navDirection) else {
                reply(nil, MisttyIPC.error(.operationFailed, "No pane in direction \(direction)"))
                return
            }

            tab.activePane = target
            reply(self.encode(self.paneResponse(target)), nil)
        }
    }

    func resizePane(id: Int, direction: String, amount: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, tab, pane) = self.store.pane(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Pane \(id) not found"))
                return
            }
            let delta = CGFloat(amount) / 100.0
            let splitDir: SplitDirection?
            let sign: CGFloat
            switch direction {
            case "left":  splitDir = .horizontal; sign = -1.0
            case "right": splitDir = .horizontal; sign = 1.0
            case "up":    splitDir = .vertical;   sign = -1.0
            case "down":  splitDir = .vertical;   sign = 1.0
            default:
                reply(nil, MisttyIPC.error(.invalidArgument, "Invalid direction: \(direction). Use left, right, up, or down"))
                return
            }
            tab.layout.resizeSplit(containing: pane, delta: delta * sign, along: splitDir)
            reply(Data("{}".utf8), nil)
        }
    }

    func activePane(reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, _, pane) = self.store.activePaneInfo() else {
                reply(nil, MisttyIPC.error(.entityNotFound, "No active pane"))
                return
            }
            reply(self.encode(self.paneResponse(pane)), nil)
        }
    }

    func sendKeys(paneId: Int, keys: String, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor [store] in
            let targetPane: MisttyPane?
            if paneId == 0 {
                targetPane = store.activePaneInfo()?.pane
            } else {
                targetPane = store.pane(byId: paneId)?.pane
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
                targetPane = self.store.activePaneInfo()?.pane
            } else {
                targetPane = self.store.pane(byId: paneId)?.pane
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

            reply(self.encode(["text": content]), nil)
        }
    }

    // MARK: - Windows

    func createWindow(reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyIPC.error(.operationFailed, "Not supported: programmatic window creation is not available with SwiftUI WindowGroup"))
    }

    func listWindows(reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            let responses = self.store.trackedWindows.map { tracked in
                WindowResponse(id: tracked.id, sessionCount: self.store.sessions.count)
            }
            reply(self.encode(responses), nil)
        }
    }

    func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let tracked = self.store.trackedWindow(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Window \(id) not found"))
                return
            }
            reply(self.encode(WindowResponse(id: tracked.id, sessionCount: self.store.sessions.count)), nil)
        }
    }

    func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let tracked = self.store.trackedWindow(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Window \(id) not found"))
                return
            }
            tracked.window.close()
            self.store.unregisterWindow(tracked.window)
            reply(self.encode([String: String]()), nil)
        }
    }

    func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let tracked = self.store.trackedWindow(byId: id) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Window \(id) not found"))
                return
            }
            tracked.window.makeKeyAndOrderFront(nil)
            reply(self.encode([String: String]()), nil)
        }
    }

    // MARK: - Popups

    func openPopup(sessionId: Int, name: String, exec: String, width: Double, height: Double, closeOnExit: Bool, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let session = self.store.session(byId: sessionId) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
                return
            }
            let definition = PopupDefinition(name: name, command: exec, width: width, height: height, closeOnExit: closeOnExit)
            session.openPopup(definition: definition)
            guard let popup = session.activePopup else {
                reply(nil, MisttyIPC.error(.operationFailed, "Failed to create popup"))
                return
            }
            reply(self.encode(self.popupResponse(popup)), nil)
        }
    }

    func closePopup(popupId: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (session, popup) = self.store.popup(byId: popupId) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Popup \(popupId) not found"))
                return
            }
            session.closePopup(popup)
            reply(self.encode([String: String]()), nil)
        }
    }

    func togglePopup(sessionId: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let session = self.store.session(byId: sessionId) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
                return
            }
            let config = MisttyConfig.load()
            guard let definition = config.popups.first(where: { $0.name == name }) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Popup definition '\(name)' not found in config"))
                return
            }
            session.togglePopup(definition: definition)
            if let popup = session.popups.first(where: { $0.definition.name == name }) {
                reply(self.encode(self.popupResponse(popup)), nil)
            } else {
                reply(self.encode([String: String]()), nil)
            }
        }
    }

    func listPopups(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let session = self.store.session(byId: sessionId) else {
                reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
                return
            }
            let responses = session.popups.map { self.popupResponse($0) }
            reply(self.encode(responses), nil)
        }
    }
}
