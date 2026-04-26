import ArgumentParser
import Foundation
import MisttyShared

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print client (mistty-cli) and server (Mistty.app) versions."
    )

    func run() {
        print("mistty-cli: \(Self.clientVersion())")

        let client = IPCClient()
        do {
            try client.ensureReachable()
            let data = try client.call("getVersion")
            let response = try JSONDecoder().decode(VersionResponse.self, from: data)
            print("Mistty.app: \(response.version) (\(response.bundleIdentifier))")
        } catch {
            print("Mistty.app: unavailable (\(error.localizedDescription))")
        }
    }

    /// The CLI binary lives at `<bundle>/Contents/MacOS/mistty-cli`. Resolve
    /// any symlink (`~/.local/bin/mistty-cli` is the common case), walk two
    /// levels up to `Contents/`, and read `Info.plist`. Returns "unknown" if
    /// the binary lives outside an `.app` bundle for any reason.
    static func clientVersion() -> String {
        guard let executable = Bundle.main.executablePath else { return "unknown" }
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let plistURL = resolved
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
            let version = plist["CFBundleShortVersionString"] as? String
        else { return "unknown" }
        return version
    }
}
