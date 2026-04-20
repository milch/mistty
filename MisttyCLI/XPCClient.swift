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
    /// Ensure the Mistty app is reachable, launching it if not. Does not retain
    /// a socket — each `call()` opens its own.
    func connect() throws {
        if probeConnection() { return }

        let launchProcess = Process()
        launchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launchProcess.arguments = ["-a", "Mistty"]
        try? launchProcess.run()
        launchProcess.waitUntilExit()

        let delays: [UInt32] = [100_000, 200_000, 400_000, 800_000, 1_600_000]
        for delay in delays {
            usleep(delay)
            if probeConnection() { return }
        }

        throw IPCClientError.connectionFailed(
            "Could not connect to Mistty.app. Is it running?"
        )
    }

    /// Send an IPC request and return the response data.
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        let fd = openSocket()
        guard fd >= 0 else {
            throw IPCClientError.connectionFailed("Could not connect to Mistty.app")
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

    // MARK: - Socket setup

    private func probeConnection() -> Bool {
        let fd = openSocket()
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }

    private func openSocket() -> Int32 {
        let path = MisttyIPC.socketPath

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            close(fd)
            return -1
        }

        return fd
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
