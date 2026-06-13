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
            let data = IPCRun.call(
                "getStateSnapshot", formatter: OutputFormatter(format: .auto))
            let json = String(decoding: data, as: UTF8.self)
            print(json)
        }
    }
}
