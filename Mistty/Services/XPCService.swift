import Foundation
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

    // MARK: - Sessions

    func createSession(name: String, directory: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void) {
        let reply = Reply(handler: reply)
        Task { @MainActor in
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

    // MARK: - Tabs (not yet implemented)

    func createTab(sessionId: Int, name: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func listTabs(sessionId: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func getTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func renameTab(id: Int, name: String, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    // MARK: - Panes (not yet implemented)

    func createPane(tabId: Int, direction: String?, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func listPanes(tabId: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func getPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func closePane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func focusPane(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func resizePane(id: Int, direction: String, amount: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func activePane(reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func sendKeys(paneId: Int, keys: String, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func runCommand(paneId: Int, command: String, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func getText(paneId: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    // MARK: - Windows (not yet implemented)

    func createWindow(reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func listWindows(reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }

    func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void) {
        notImplemented(reply)
    }
}
