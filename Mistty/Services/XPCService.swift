import AppKit
import Foundation
import GhosttyKit
import MisttyShared

/// Wraps a non-Sendable XPC reply closure so it can be captured by a @MainActor Task.
/// XPC reply handlers are thread-safe by design — they just aren't annotated as @Sendable.
private struct Reply: @unchecked Sendable {
    let handler: (Data?, Error?) -> Void

    func callAsFunction(_ data: Data?, _ error: Error?) {
        handler(data, error)
    }
}

final class MisttyXPCService: NSObject, MisttyServiceProtocol, @unchecked Sendable {
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
        super.init()
    }

    // MARK: - Helpers

    private func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private func notImplemented(_ reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not implemented"))
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

    // MARK: - Sessions

    func createSession(name: String, directory: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            // TODO: exec parameter — launch specified command in the first pane
            let dir = URL(fileURLWithPath: directory ?? FileManager.default.homeDirectoryForCurrentUser.path)
            let session = self.store.createSession(name: name, directory: dir)
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
                reply(nil, MisttyXPC.error(.entityNotFound, "Session \(id) not found"))
                return
            }
            reply(self.encode(self.sessionResponse(session)), nil)
        }
    }

    func closeSession(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let session = self.store.session(byId: id) else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Session \(id) not found"))
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
            // TODO: exec parameter — launch specified command in the first pane
            guard let session = self.store.session(byId: sessionId) else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Session \(sessionId) not found"))
                return
            }
            session.addTab()
            guard let tab = session.tabs.last else {
                reply(nil, MisttyXPC.error(.operationFailed, "Failed to create tab"))
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
                reply(nil, MisttyXPC.error(.entityNotFound, "Session \(sessionId) not found"))
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
                reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(id) not found"))
                return
            }
            reply(self.encode(self.tabResponse(tab)), nil)
        }
    }

    func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (session, tab) = self.store.tab(byId: id) else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(id) not found"))
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
                reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(id) not found"))
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
                reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(tabId) not found"))
                return
            }
            let splitDir: SplitDirection = direction == "horizontal" ? .horizontal : .vertical
            tab.splitActivePane(direction: splitDir)
            guard let newPane = tab.panes.last else {
                reply(nil, MisttyXPC.error(.operationFailed, "Failed to create pane"))
                return
            }
            reply(self.encode(self.paneResponse(newPane)), nil)
        }
    }

    func listPanes(tabId: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, tab) = self.store.tab(byId: tabId) else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Tab \(tabId) not found"))
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
                reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(id) not found"))
                return
            }
            reply(self.encode(self.paneResponse(pane)), nil)
        }
    }

    func closePane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, tab, pane) = self.store.pane(byId: id) else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(id) not found"))
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
                reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(id) not found"))
                return
            }
            self.store.activeSession = session
            session.activeTab = tab
            tab.activePane = pane
            reply(self.encode(self.paneResponse(pane)), nil)
        }
    }

    func resizePane(id: Int, direction: String, amount: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            guard let (_, tab, pane) = self.store.pane(byId: id) else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(id) not found"))
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
                reply(nil, MisttyXPC.error(.invalidArgument, "Invalid direction: \(direction). Use left, right, up, or down"))
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
                reply(nil, MisttyXPC.error(.entityNotFound, "No active pane"))
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
                reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(paneId) not found"))
                return
            }
            let view = pane.surfaceView
            guard let surface = view.surface else {
                reply(nil, MisttyXPC.error(.operationFailed, "Pane has no active surface"))
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
            guard targetPane != nil else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Pane \(paneId) not found"))
                return
            }
            reply(nil, MisttyXPC.error(.operationFailed, "Not yet implemented: requires ghostty surface integration"))
        }
    }

    // MARK: - Windows

    func createWindow(reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, MisttyXPC.error(.operationFailed, "Not supported: programmatic window creation is not available with SwiftUI WindowGroup"))
    }

    func listWindows(reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            let windows = NSApplication.shared.windows.filter { $0.isVisible }
            let responses = windows.enumerated().map { index, _ in
                WindowResponse(id: index + 1, sessionCount: self.store.sessions.count)
            }
            reply(self.encode(responses), nil)
        }
    }

    func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            let windows = NSApplication.shared.windows.filter { $0.isVisible }
            let index = id - 1
            guard index >= 0 && index < windows.count else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Window \(id) not found"))
                return
            }
            reply(self.encode(WindowResponse(id: id, sessionCount: self.store.sessions.count)), nil)
        }
    }

    func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            let windows = NSApplication.shared.windows.filter { $0.isVisible }
            let index = id - 1
            guard index >= 0 && index < windows.count else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Window \(id) not found"))
                return
            }
            windows[index].close()
            reply(self.encode([String: String]()), nil)
        }
    }

    func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
            let windows = NSApplication.shared.windows.filter { $0.isVisible }
            let index = id - 1
            guard index >= 0 && index < windows.count else {
                reply(nil, MisttyXPC.error(.entityNotFound, "Window \(id) not found"))
                return
            }
            windows[index].makeKeyAndOrderFront(nil)
            reply(self.encode([String: String]()), nil)
        }
    }
}
