import Foundation
import MisttyShared

enum XPCClientError: Error, CustomStringConvertible {
    case connectionFailed(String)

    var description: String {
        switch self {
        case .connectionFailed(let message):
            return message
        }
    }
}

final class XPCClient: @unchecked Sendable {
    private var connection: NSXPCConnection?

    func connect() throws -> MisttyServiceProtocol {
        // Attempt to connect; on first failure launch the app and retry with backoff.
        if let proxy = tryConnect() {
            return proxy
        }

        // Launch the app
        let launchProcess = Process()
        launchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launchProcess.arguments = ["-a", "Mistty"]
        try? launchProcess.run()
        launchProcess.waitUntilExit()

        // Retry with exponential backoff: 100ms, 200ms, 400ms, 800ms, 1600ms (~3s total)
        let delays: [UInt32] = [100_000, 200_000, 400_000, 800_000, 1_600_000]
        for delay in delays {
            usleep(delay)
            if let proxy = tryConnect() {
                return proxy
            }
        }

        throw XPCClientError.connectionFailed(
            "Could not connect to Mistty.app. Is it installed?"
        )
    }

    private func tryConnect() -> MisttyServiceProtocol? {
        let conn = NSXPCConnection(machServiceName: MisttyXPC.serviceName)
        conn.remoteObjectInterface = NSXPCInterface(with: MisttyServiceProtocol.self)
        conn.resume()

        let semaphore = DispatchSemaphore(value: 0)
        var connectionError: Error?

        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            connectionError = error
            semaphore.signal()
        } as? MisttyServiceProtocol

        guard let proxy = proxy else {
            conn.invalidate()
            return nil
        }

        // Test the connection by calling a lightweight method
        proxy.listSessions { _, error in
            if let error = error {
                connectionError = error
            }
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + .milliseconds(500)
        if semaphore.wait(timeout: timeout) == .timedOut {
            conn.invalidate()
            return nil
        }

        if connectionError != nil {
            conn.invalidate()
            return nil
        }

        self.connection = conn
        return proxy
    }

    deinit {
        connection?.invalidate()
    }
}
