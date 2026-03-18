import Darwin
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

/// CLI-side IPC client using Unix domain sockets to communicate with the Mistty app.
final class IPCClient {
    private var socketFD: Int32 = -1

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
        let path = MisttyIPC.socketPath

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        // Set SO_NOSIGPIPE
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
            return false
        }

        socketFD = fd
        return true
    }

    /// Send an IPC request and return the response data.
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        guard socketFD >= 0 else {
            throw IPCClientError.connectionFailed("Not connected")
        }

        // Build request
        var request = params
        request["method"] = method
        let requestData = try JSONSerialization.data(withJSONObject: request)

        // Write length-prefixed request
        var length = UInt32(requestData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        try writeAll(data: lengthData)
        try writeAll(data: requestData)

        // Read length-prefixed response
        let responseLengthData = try readExact(count: 4)
        let responseLength = responseLengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard responseLength > 0, responseLength <= MisttyIPC.maxMessageSize else {
            throw IPCClientError.connectionFailed("Invalid response length")
        }

        let responseData = try readExact(count: Int(responseLength))

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

    deinit {
        if socketFD >= 0 { close(socketFD) }
    }

    // MARK: - Socket I/O Helpers

    private func readExact(count: Int) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(socketFD, ptr.baseAddress! + offset, count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                throw IPCClientError.connectionFailed("Read failed")
            }
            offset += n
        }
        return buffer
    }

    private func writeAll(data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { ptr in
                Darwin.write(socketFD, ptr.baseAddress! + offset, data.count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                throw IPCClientError.connectionFailed("Write failed")
            }
            offset += n
        }
    }
}
