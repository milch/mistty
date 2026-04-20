import Darwin
import Foundation
import MisttyShared

enum IPCClientError: LocalizedError, CustomStringConvertible {
    case connectionFailed(String)
    case remoteError(String)

    var description: String {
        switch self {
        case .connectionFailed(let message): return message
        case .remoteError(let message): return message
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
        let requestData = try JSONSerialization.data(withJSONObject: request)

        var length = UInt32(requestData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        try writeAll(fd: fd, data: lengthData)
        try writeAll(fd: fd, data: requestData)

        let responseLengthData = try readExact(fd: fd, count: 4)
        let responseLength = responseLengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard responseLength > 0, responseLength <= MisttyIPC.maxMessageSize else {
            throw IPCClientError.connectionFailed("Invalid response length")
        }

        let responseData = try readExact(fd: fd, count: Int(responseLength))

        guard !responseData.isEmpty else {
            throw IPCClientError.connectionFailed("Empty response")
        }

        let statusByte = responseData[0]
        let payload = responseData.dropFirst()

        if statusByte == 0x01 {
            let message = String(data: Data(payload), encoding: .utf8) ?? "Unknown error"
            throw IPCClientError.remoteError(message)
        }

        return Data(payload)
    }

    // MARK: - Probe

    private func probeConnection() -> Bool {
        let fd = UnixSocket.connect(path: MisttyIPC.socketPath)
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }

    // MARK: - Socket I/O Helpers

    private func readExact(fd: Int32, count: Int) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress! + offset, count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                throw IPCClientError.connectionFailed("Read failed")
            }
            offset += n
        }
        return buffer
    }

    private func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress! + offset, data.count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                throw IPCClientError.connectionFailed("Write failed")
            }
            offset += n
        }
    }
}
