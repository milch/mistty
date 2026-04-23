import ArgumentParser
import Foundation
import MisttyShared

struct DebugCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Developer diagnostics.",
        subcommands: [StateCommand.self]
    )
}

extension DebugCommand {
    struct StateCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "state",
            abstract: "Print the live WorkspaceSnapshot as JSON."
        )

        func run() throws {
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("getStateSnapshot")
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }

            let json = String(decoding: data, as: UTF8.self)
            print(json)
        }
    }
}
