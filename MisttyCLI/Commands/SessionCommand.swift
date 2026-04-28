import ArgumentParser
import Foundation
import MisttyShared

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage sessions",
        subcommands: [
            Create.self,
            List.self,
            Get.self,
            Close.self,
        ]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new session")

        @Option(name: .long, help: "Session name")
        var name: String = "Default"

        @Option(name: .long, help: "Working directory")
        var directory: String?

        @Option(name: .long, help: "Executable to run")
        var exec: String?

        @Option(name: .long, help: "Target window id. Defaults to the focused window.")
        var window: Int?

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            var params: [String: Any] = ["name": name]
            if let directory { params["directory"] = directory }
            if let exec { params["exec"] = exec }
            if let window { params["windowID"] = window }

            let data: Data
            do {
                data = try client.call("createSession", params)
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let session = try JSONDecoder().decode(SessionResponse.self, from: data)
            formatter.print(session)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all sessions")

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("listSessions")
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let sessions = try JSONDecoder().decode([SessionResponse].self, from: data)
            formatter.print(sessions)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get session details")

        @Argument(help: "Session ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("getSession", ["id": id])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let session = try JSONDecoder().decode(SessionResponse.self, from: data)
            formatter.print(session)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a session")

        @Argument(help: "Session ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            do {
                _ = try client.call("closeSession", ["id": id])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Session \(id) closed")
        }
    }
}
