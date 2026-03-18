import CoreFoundation
import Foundation
import MisttyShared

enum IPCClientError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case remoteError(String)

    var description: String {
        switch self {
        case .connectionFailed(let message): return message
        case .remoteError(let message): return message
        }
    }
}

/// CLI-side IPC client using CFMessagePort to communicate with the Mistty app.
final class IPCClient {
    private var port: CFMessagePort?

    /// Connect to the running Mistty app, launching it if needed.
    func connect() throws {
        if tryConnect() { return }

        // Launch the app
        let launchProcess = Process()
        launchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launchProcess.arguments = ["-a", "Mistty"]
        try? launchProcess.run()
        launchProcess.waitUntilExit()

        // Retry with exponential backoff
        let delays: [UInt32] = [100_000, 200_000, 400_000, 800_000, 1_600_000]
        for delay in delays {
            usleep(delay)
            if tryConnect() { return }
        }

        throw IPCClientError.connectionFailed(
            "Could not connect to Mistty.app. Is it running?"
        )
    }

    private func tryConnect() -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, MisttyIPC.serviceName as CFString) else {
            return false
        }
        port = remote
        return true
    }

    /// Send an IPC request and return the response data.
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        guard let port else {
            throw IPCClientError.connectionFailed("Not connected")
        }

        var request = params
        request["method"] = method
        let requestData = try JSONSerialization.data(withJSONObject: request)

        var response: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            port, 0, requestData as CFData,
            /* sendTimeout */ 5, /* recvTimeout */ 30,
            CFRunLoopMode.defaultMode.rawValue, &response
        )

        guard status == kCFMessagePortSuccess else {
            throw IPCClientError.connectionFailed("Send failed (status \(status))")
        }

        guard let responseData = response?.takeRetainedValue() as Data? else {
            throw IPCClientError.connectionFailed("No response")
        }

        guard !responseData.isEmpty else {
            throw IPCClientError.connectionFailed("Empty response")
        }

        let statusByte = responseData[0]
        let payload = responseData.dropFirst()

        if statusByte == 0x01 {
            // Error response
            let message = String(data: Data(payload), encoding: .utf8) ?? "Unknown error"
            throw IPCClientError.remoteError(message)
        }

        return Data(payload)
    }
}
