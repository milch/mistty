import Darwin
import Foundation
import MisttyShared
import os

/// Thread-safe state shared between the main thread and the accept loop.
private struct ListenerState: Sendable {
    var serverFD: Int32 = -1
    var running = false
}

/// Unix domain socket IPC listener. The app binds to a socket and accepts
/// one-shot connections from the CLI: read request, dispatch, write response, close.
@MainActor
final class IPCListener {
    private let service: MisttyIPCService
    private let state = OSAllocatedUnfairLock(initialState: ListenerState())
    private let queue = DispatchQueue(label: "com.mistty.ipc-listener", qos: .userInitiated)

    init(service: MisttyIPCService) {
        self.service = service
    }

    func start() {
        let path = MisttyIPC.socketPath

        // Ensure parent directory exists with 0700 permissions
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Unconditionally unlink any stale socket
        unlink(path)

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("Warning: failed to create IPC socket: \(String(cString: strerror(errno)))")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            print("Warning: socket path too long")
            Darwin.close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("Warning: failed to bind IPC socket: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        // Listen
        guard Darwin.listen(fd, 5) == 0 else {
            print("Warning: failed to listen on IPC socket: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        // Publish state atomically before launching accept loop
        state.withLock { s in
            s.serverFD = fd
            s.running = true
        }

        let service = self.service
        queue.async { [state] in
            IPCListener.acceptLoop(state: state, service: service)
        }
    }

    func stop() {
        let fd = state.withLock { s -> Int32 in
            s.running = false
            let fd = s.serverFD
            s.serverFD = -1
            return fd
        }
        // Closing the fd unblocks the accept() call in the background thread
        if fd >= 0 { Darwin.close(fd) }
        unlink(MisttyIPC.socketPath)
    }

    // MARK: - Accept Loop

    private nonisolated static func acceptLoop(state: OSAllocatedUnfairLock<ListenerState>, service: MisttyIPCService) {
        while true {
            let fd = state.withLock { $0.running ? $0.serverFD : -1 }
            guard fd >= 0 else { break }

            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else {
                // Check if we were stopped (fd closed)
                let stillRunning = state.withLock { $0.running }
                if !stillRunning { break }
                continue
            }

            // Set SO_NOSIGPIPE to avoid SIGPIPE on write to closed socket
            var on: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            // Set read/write timeout (5 seconds)
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            // Handle connection on a separate queue to not block accept loop
            DispatchQueue.global(qos: .userInitiated).async {
                handleConnection(clientFD, service: service)
            }
        }
    }

    // MARK: - Connection Handling

    private nonisolated static func handleConnection(_ fd: Int32, service: MisttyIPCService) {
        defer { Darwin.close(fd) }

        // Read length prefix (4 bytes, big-endian UInt32)
        guard let lengthBytes = readExact(fd: fd, count: 4) else { return }
        let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard length > 0, length <= MisttyIPC.maxMessageSize else { return }

        // Read request payload
        guard let requestData = readExact(fd: fd, count: Int(length)) else { return }

        // Parse request
        guard let json = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let method = json["method"] as? String
        else {
            writeResponse(fd: fd, data: errorResponse("Invalid request format"))
            return
        }

        // Dispatch to service (synchronous via semaphore — service methods are @MainActor)
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: String?

        let reply: (Data?, Error?) -> Void = { data, error in
            responseData = data
            responseError = error?.localizedDescription
            semaphore.signal()
        }

        IPCListener.dispatch(service: service, method: method, params: json, reply: reply)
        semaphore.wait()

        if let errorMsg = responseError {
            writeResponse(fd: fd, data: errorResponse(errorMsg))
        } else {
            var result = Data([0x00])
            if let d = responseData { result.append(d) }
            writeResponse(fd: fd, data: result)
        }
    }

    private nonisolated static func errorResponse(_ message: String) -> Data {
        var result = Data([0x01])
        result.append(Data(message.utf8))
        return result
    }

    // MARK: - Socket I/O Helpers

    /// Read exactly `count` bytes, looping for short reads and EINTR. Returns nil on error/timeout.
    private nonisolated static func readExact(fd: Int32, count: Int) -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress! + offset, count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            offset += n
        }
        return buffer
    }

    /// Write response with length prefix, looping for short writes.
    private nonisolated static func writeResponse(fd: Int32, data: Data) {
        // Write length prefix
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        writeAll(fd: fd, data: lengthData)
        // Write payload
        writeAll(fd: fd, data: data)
    }

    private nonisolated static func writeAll(fd: Int32, data: Data) {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress! + offset, data.count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            offset += n
        }
    }

    // MARK: - Method Dispatch

    nonisolated static func dispatch(
        service: MisttyIPCService,
        method: String,
        params: [String: Any],
        reply: @escaping (Data?, Error?) -> Void
    ) {
        func str(_ key: String) -> String? { params[key] as? String }
        func int(_ key: String) -> Int { params[key] as? Int ?? 0 }
        func dbl(_ key: String) -> Double { params[key] as? Double ?? 0 }
        func boo(_ key: String) -> Bool { params[key] as? Bool ?? false }

        switch method {
        // Sessions
        case "createSession":
            service.createSession(name: str("name") ?? "Default", directory: str("directory"), exec: str("exec"), reply: reply)
        case "listSessions":
            service.listSessions(reply: reply)
        case "getSession":
            service.getSession(id: int("id"), reply: reply)
        case "closeSession":
            service.closeSession(id: int("id"), reply: reply)

        // Tabs
        case "createTab":
            service.createTab(sessionId: int("sessionId"), name: str("name"), exec: str("exec"), reply: reply)
        case "listTabs":
            service.listTabs(sessionId: int("sessionId"), reply: reply)
        case "getTab":
            service.getTab(id: int("id"), reply: reply)
        case "closeTab":
            service.closeTab(id: int("id"), reply: reply)
        case "renameTab":
            service.renameTab(id: int("id"), name: str("name") ?? "", reply: reply)

        // Panes
        case "createPane":
            service.createPane(tabId: int("tabId"), direction: str("direction"), reply: reply)
        case "listPanes":
            service.listPanes(tabId: int("tabId"), reply: reply)
        case "getPane":
            service.getPane(id: int("id"), reply: reply)
        case "closePane":
            service.closePane(id: int("id"), reply: reply)
        case "focusPane":
            service.focusPane(id: int("id"), reply: reply)
        case "focusPaneByDirection":
            service.focusPaneByDirection(direction: str("direction") ?? "", sessionId: int("sessionId"), reply: reply)
        case "resizePane":
            service.resizePane(id: int("id"), direction: str("direction") ?? "", amount: int("amount"), reply: reply)
        case "sendKeys":
            service.sendKeys(paneId: int("paneId"), keys: str("keys") ?? "", reply: reply)
        case "runCommand":
            service.runCommand(paneId: int("paneId"), command: str("command") ?? "", reply: reply)
        case "getText":
            service.getText(paneId: int("paneId"), reply: reply)
        case "activePane":
            service.activePane(reply: reply)

        // Windows
        case "createWindow":
            service.createWindow(reply: reply)
        case "listWindows":
            service.listWindows(reply: reply)
        case "getWindow":
            service.getWindow(id: int("id"), reply: reply)
        case "closeWindow":
            service.closeWindow(id: int("id"), reply: reply)
        case "focusWindow":
            service.focusWindow(id: int("id"), reply: reply)

        // Popups
        case "openPopup":
            service.openPopup(
                sessionId: int("sessionId"), name: str("name") ?? "",
                exec: str("exec") ?? "", width: dbl("width"), height: dbl("height"),
                closeOnExit: boo("closeOnExit"), reply: reply)
        case "closePopup":
            service.closePopup(popupId: int("popupId"), reply: reply)
        case "togglePopup":
            service.togglePopup(sessionId: int("sessionId"), name: str("name") ?? "", reply: reply)
        case "listPopups":
            service.listPopups(sessionId: int("sessionId"), reply: reply)

        default:
            reply(nil, MisttyIPC.error(.operationFailed, "Unknown method: \(method)"))
        }
    }
}
