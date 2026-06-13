import Darwin
import Foundation

/// Shared low-level helpers for the Unix-domain-socket IPC channel between
/// the Mistty app and the CLI.
public enum UnixSocket {
    /// Fill a `sockaddr_un` from a UTF-8 path. Returns nil if the path is
    /// longer than `sun_path` permits.
    public static func makeSockaddr(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }
        return addr
    }

    /// Open a stream socket and connect to `path`. Returns the connected fd
    /// on success, `nil` on failure (with the underlying errno preserved).
    public static func connect(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        guard var addr = makeSockaddr(path: path) else {
            close(fd)
            return -1
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let savedErrno = errno
            close(fd)
            errno = savedErrno
            return -1
        }
        return fd
    }

    /// Read exactly `count` bytes, looping on EINTR and short reads.
    /// Returns nil on error, EOF, or timeout.
    public static func readExact(fd: Int32, count: Int) -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress! + offset, count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            offset += n
        }
        return buffer
    }

    /// Write all bytes, looping on EINTR and short writes.
    @discardableResult
    public static func writeAll(fd: Int32, data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress! + offset, data.count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    /// Write a frame: 4-byte big-endian length prefix + payload.
    @discardableResult
    public static func sendFrame(fd: Int32, payload: Data) -> Bool {
        var length = UInt32(payload.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        return writeAll(fd: fd, data: lengthData) && writeAll(fd: fd, data: payload)
    }

    /// Read a frame: 4-byte big-endian length prefix + payload. Returns
    /// nil on I/O error or when the length is 0 or exceeds `maxSize`.
    public static func receiveFrame(fd: Int32, maxSize: Int) -> Data? {
        guard let lengthBytes = readExact(fd: fd, count: 4) else { return nil }
        let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, Int(length) <= maxSize else { return nil }
        return readExact(fd: fd, count: Int(length))
    }
}
