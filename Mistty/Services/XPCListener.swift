import Foundation
import MisttyShared

@MainActor
final class MisttyXPCListener: NSObject {
    private var listener: NSXPCListener?
    nonisolated(unsafe) private let service: MisttyServiceProtocol

    init(service: MisttyServiceProtocol) {
        self.service = service
        super.init()
    }

    func start() {
        let listener = NSXPCListener(machServiceName: MisttyXPC.serviceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    func stop() {
        listener?.invalidate()
        listener = nil
    }
}

extension MisttyXPCListener: NSXPCListenerDelegate {
    nonisolated func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: MisttyServiceProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}
