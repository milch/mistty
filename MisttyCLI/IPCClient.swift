import Darwin
import Foundation
import MisttyShared

enum IPCClientError: LocalizedError, CustomStringConvertible {
    case connectionFailed(String)
    /// Legacy / plain-text server error (no structured code on the wire).
    /// Kept distinct so VersionCommand's `where msg.contains(...)` matching
    /// against older servers keeps working.
    case remoteError(String)
    /// Structured server error carrying a code, so the CLI can choose a
    /// distinct exit status.
    case remoteCoded(code: MisttyIPC.ErrorCode, message: String)

    var description: String {
        switch self {
        case .connectionFailed(let message): return message
        case .remoteError(let message): return message
        case .remoteCoded(_, let message): return message
        }
    }

    var errorDescription: String? { description }
}

/// CLI-side IPC client using Unix domain sockets to communicate with the Mistty app.
///
/// The app's IPC listener uses one connection per request (read, dispatch, write,
/// close). To support commands that issue multiple calls, every `call()` opens a
/// fresh socket and closes it when done.
final class IPCClient {
    /// One-time launch+probe gate; `ensureReachable()` short-circuits once true.
    private var verifiedReachable = false

    /// Ensure the Mistty app is reachable, launching it if not. Cheap and
    /// idempotent: after the first successful probe this is a no-op.
    func ensureReachable() throws {
        if verifiedReachable { return }
        if probeConnection() {
            verifiedReachable = true
            return
        }

        let launchProcess = Process()
        launchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launchProcess.arguments = ["-a", "Mistty"]
        try? launchProcess.run()
        launchProcess.waitUntilExit()

        // Total worst-case wait: ~3.1s. Print a single notice on the first
        // miss so users know the delay is intentional.
        FileHandle.standardError.write(Data("Waiting for Mistty.app to launch...\n".utf8))
        let delays: [UInt32] = [100_000, 200_000, 400_000, 800_000, 1_600_000]
        for delay in delays {
            usleep(delay)
            if probeConnection() {
                verifiedReachable = true
                return
            }
        }

        throw IPCClientError.connectionFailed(
            "Could not connect to Mistty.app after launch attempt. Is it installed?"
        )
    }

    /// Send an IPC request and return the response data.
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        let fd = UnixSocket.connect(path: MisttyIPC.socketPath)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw IPCClientError.connectionFailed("Could not connect to Mistty.app (\(reason))")
        }
        defer { Darwin.close(fd) }

        var request = params
        request["method"] = method
        request["v"] = MisttyIPC.protocolVersion
        let requestData = try JSONSerialization.data(withJSONObject: request)

        guard UnixSocket.sendFrame(fd: fd, payload: requestData) else {
            throw IPCClientError.connectionFailed("Write failed")
        }
        guard let responseData = UnixSocket.receiveFrame(
            fd: fd, maxSize: Int(MisttyIPC.maxMessageSize))
        else {
            throw IPCClientError.connectionFailed("Read failed")
        }

        guard !responseData.isEmpty else {
            throw IPCClientError.connectionFailed("Empty response")
        }

        let statusByte = responseData[0]
        let payload = Data(responseData.dropFirst())

        if statusByte == 0x01 {
            // v1+ server: structured {code, message}. Old server: plain text,
            // which decodes to nil here so we fall back to remoteError.
            if let structured = MisttyIPC.decodeWireError(payload) {
                throw IPCClientError.remoteCoded(
                    code: structured.code, message: structured.message)
            }
            let message = String(data: payload, encoding: .utf8) ?? "Unknown error"
            throw IPCClientError.remoteError(message)
        }

        return payload
    }

    // MARK: - Probe

    private func probeConnection() -> Bool {
        let fd = UnixSocket.connect(path: MisttyIPC.socketPath)
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }
}
