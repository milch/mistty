import CoreFoundation
import Foundation
import MisttyShared

/// CFMessagePort callback — dispatches JSON request to the service and returns JSON response.
/// Response format: first byte is status (0 = success, 1 = error), rest is payload.
private func ipcMessageCallback(
    _ port: CFMessagePort?,
    _ msgid: Int32,
    _ data: CFData?,
    _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CFData>? {
    guard let info, let data else { return nil }
    let service = Unmanaged<MisttyIPCService>.fromOpaque(info).takeUnretainedValue()
    let requestData = data as Data

    guard let json = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
          let method = json["method"] as? String
    else {
        return ipcErrorResponse("Invalid request format")
    }

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
        return ipcErrorResponse(errorMsg)
    }
    var result = Data([0x00])
    if let d = responseData { result.append(d) }
    return Unmanaged.passRetained(result as CFData)
}

private func ipcErrorResponse(_ message: String) -> Unmanaged<CFData> {
    var result = Data([0x01])
    result.append(Data(message.utf8))
    return Unmanaged.passRetained(result as CFData)
}

/// CFMessagePort-based IPC listener. Replaces XPC Mach service approach which required
/// launchd management and caused duplicate app launches.
@MainActor
final class IPCListener {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    nonisolated(unsafe) private let service: MisttyIPCService

    init(service: MisttyIPCService) {
        self.service = service
    }

    func start() {
        var ctx = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(service).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        port = CFMessagePortCreateLocal(
            nil,
            MisttyIPC.serviceName as CFString,
            ipcMessageCallback,
            &ctx,
            nil
        )

        guard let port else {
            print("Warning: failed to create IPC message port (is another instance running?)")
            return
        }

        source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = nil
        }
        if let port {
            CFMessagePortInvalidate(port)
            self.port = nil
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
