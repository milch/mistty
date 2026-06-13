import Foundation

/// Server identity returned by `getVersion`. Encoded as JSON over the
/// IPC socket — keep this struct + its keys stable so older CLIs can
/// still parse responses from a newer server.
public struct VersionResponse: Codable, Sendable, Equatable {
    public let version: String
    public let bundleIdentifier: String

    public init(version: String, bundleIdentifier: String) {
        self.version = version
        self.bundleIdentifier = bundleIdentifier
    }
}
