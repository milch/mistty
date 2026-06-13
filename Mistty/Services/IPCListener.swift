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

  /// At most this many connections may be in flight at once. Each connection
  /// parks a GCD worker on the main-actor reply; without a cap, a script
  /// firing many calls while the main thread is busy (e.g. a modal NSAlert
  /// at launch) would grow the pool toward GCD's ~64-thread limit. The
  /// accept loop blocks here until a slot frees — backpressure, not collapse.
  private nonisolated static let connectionSlots = DispatchSemaphore(value: 16)

  init(service: MisttyIPCService) {
    self.service = service
  }

  func start() {
    let path = MisttyIPC.serverSocketPath

    // Ensure parent directory exists with 0700 permissions. createDirectory
    // only applies the attributes when it creates the directory, so also
    // re-assert 0700 on every start — a perms drift on an existing dir
    // would otherwise silently expose the socket (which grants keystroke
    // injection and screen reads to anyone who can connect).
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: dir)

    // Unconditionally unlink any stale socket
    unlink(path)

    // Create socket
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      print("Warning: failed to create IPC socket: \(String(cString: strerror(errno)))")
      return
    }

    // Bind
    guard var addr = UnixSocket.makeSockaddr(path: path) else {
      print("Warning: socket path too long")
      Darwin.close(fd)
      return
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

    // The socket file's mode is umask-dependent after bind (usually
    // world-connectable if the parent dir were ever traversable). Clamp it
    // to owner-only as a second layer behind the directory perms.
    chmod(path, 0o600)

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
    unlink(MisttyIPC.serverSocketPath)
  }

  // MARK: - Accept Loop

  private nonisolated static func acceptLoop(
    state: OSAllocatedUnfairLock<ListenerState>, service: MisttyIPCService
  ) {
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

      // Belt-and-braces peer check: only same-uid clients. Filesystem
      // perms are the primary gate, but they're a single layer — this
      // keeps the socket closed to other local users even if directory
      // permissions drift.
      var peerUID: uid_t = 0
      var peerGID: gid_t = 0
      guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == getuid() else {
        Darwin.close(clientFD)
        continue
      }

      // Set SO_NOSIGPIPE to avoid SIGPIPE on write to closed socket
      var on: Int32 = 1
      setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

      // Set read/write timeout (5 seconds)
      var tv = timeval(tv_sec: 5, tv_usec: 0)
      setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

      // Acquire a slot before dispatching; blocks the accept loop when all
      // 16 are in flight so workers can't pile up faster than the main
      // actor drains them.
      connectionSlots.wait()
      DispatchQueue.global(qos: .userInitiated).async {
        defer { connectionSlots.signal() }
        handleConnection(clientFD, service: service)
      }
    }
  }

  // MARK: - Connection Handling

  private nonisolated static func handleConnection(_ fd: Int32, service: MisttyIPCService) {
    defer { Darwin.close(fd) }

    guard let requestData = UnixSocket.receiveFrame(fd: fd, maxSize: Int(MisttyIPC.maxMessageSize))
    else { return }

    // Parse request. This happens before we know the client's protocol
    // version, so a parse failure replies with plain text (a v1 client
    // still decodes it via its plain-text fallback).
    guard let json = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
      let method = json["method"] as? String
    else {
      UnixSocket.sendFrame(fd: fd, payload: errorResponse("Invalid request format"))
      return
    }

    // v0 (key absent) = legacy client → plain-text errors; v1+ → structured.
    let clientVersion = json["v"] as? Int ?? 0

    // Dispatch to service (synchronous via semaphore — service methods are @MainActor)
    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var responseError: Error?

    let reply: (Data?, Error?) -> Void = { data, error in
      responseData = data
      responseError = error
      semaphore.signal()
    }

    IPCListener.dispatch(service: service, method: method, params: json, reply: reply)

    // Bound the wait so a wedged main thread (e.g. a modal NSAlert) can't
    // park this worker forever. On timeout we reply and return WITHOUT
    // reading responseData/responseError — a late reply then only writes
    // to the (heap-boxed) captured vars, never the closed fd.
    if semaphore.wait(timeout: .now() + 10) == .timedOut {
      let err = MisttyIPC.error(
        .operationFailed, "Mistty.app did not respond within 10s (main thread busy?)")
      UnixSocket.sendFrame(fd: fd, payload: errorFrame(err, clientVersion: clientVersion))
      return
    }

    if let error = responseError {
      UnixSocket.sendFrame(fd: fd, payload: errorFrame(error, clientVersion: clientVersion))
    } else {
      var result = Data([0x00])
      if let d = responseData { result.append(d) }
      UnixSocket.sendFrame(fd: fd, payload: result)
    }
  }

  /// `[0x01]` status byte + a plain-text message. Used only for the
  /// pre-version-known parse-error path.
  private nonisolated static func errorResponse(_ message: String) -> Data {
    var result = Data([0x01])
    result.append(Data(message.utf8))
    return result
  }

  /// `[0x01]` status byte + a structured `WireError` for v1+ clients, or
  /// the plain-text `localizedDescription` for legacy clients.
  private nonisolated static func errorFrame(_ error: Error, clientVersion: Int) -> Data {
    var result = Data([0x01])
    if clientVersion >= 1 {
      result.append(MisttyIPC.encodeWireError(error))
    } else {
      result.append(Data(error.localizedDescription.utf8))
    }
    return result
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
      let windowID = params["windowID"] as? Int
      // `name` is optional on the wire — passing nil lets the receiver use
      // its default-name fallback (currently "Default") without promoting
      // that fallback to customName, so the cwd-derived sidebarLabel still
      // wins when --name was omitted on the CLI.
      service.createSession(
        name: str("name"), directory: str("directory"), exec: str("exec"),
        windowID: windowID, reply: reply
      )
    case "listSessions":
      service.listSessions(reply: reply)
    case "getSession":
      service.getSession(id: int("id"), reply: reply)
    case "closeSession":
      service.closeSession(id: int("id"), reply: reply)
    case "reparentSession":
      service.reparentSession(id: int("id"), directory: str("directory") ?? "", reply: reply)

    // Tabs
    case "createTab":
      service.createTab(
        sessionId: int("sessionId"), name: str("name"), exec: str("exec"), reply: reply)
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
      service.focusPaneByDirection(
        direction: str("direction") ?? "", sessionId: int("sessionId"), reply: reply)
    case "resizePane":
      service.resizePane(
        id: int("id"), direction: str("direction") ?? "", amount: int("amount"), reply: reply)
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

    // Debug
    case "getStateSnapshot":
      service.getStateSnapshot(reply: reply)

    // Config
    case "reloadConfig":
      service.reloadConfig(reply: reply)

    // Meta
    case "getVersion":
      service.getVersion(reply: reply)

    default:
      reply(nil, MisttyIPC.error(.operationFailed, "Unknown method: \(method)"))
    }
  }
}
