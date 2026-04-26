import ArgumentParser
import Foundation
import MachO
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
        } catch IPCClientError.remoteError(let msg) where msg.contains("Unknown method") {
            // Server pre-dates the getVersion RPC. Distinguish from "not
            // running at all" because reinstall is the actionable fix.
            print("Mistty.app: running but pre-dates `getVersion` — reinstall to refresh")
        } catch {
            print("Mistty.app: unavailable (\(error.localizedDescription))")
        }
    }

    /// Read the version from the `__TEXT,__info_plist` section embedded
    /// into our own mach-o at link time (see Package.swift's `-sectcreate`
    /// flag). The embedded copy is immune to symlinks, surrounding `.app`
    /// layout, and bundle resolution — we get the same plist data the
    /// kernel already loaded into our address space.
    static func clientVersion() -> String {
        guard let data = embeddedInfoPlist(),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
            let version = plist["CFBundleShortVersionString"] as? String
        else { return "unknown" }
        return version
    }

    /// Locate the `__TEXT,__info_plist` section in the running binary's
    /// mach-o image and return its bytes. `_dyld_get_image_header(0)` is
    /// the main executable; `getsectiondata` walks the load commands to
    /// find the named section without a filesystem call.
    private static func embeddedInfoPlist() -> Data? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        let mh = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var size: UInt = 0
        guard let ptr = getsectiondata(mh, "__TEXT", "__info_plist", &size),
            size > 0
        else { return nil }
        return Data(bytes: ptr, count: Int(size))
    }
}
