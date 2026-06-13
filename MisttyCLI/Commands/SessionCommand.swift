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
            Reparent.self,
        ]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new session")

        @Option(name: .long, help: "Session name (overrides the directory-derived sidebar label)")
        var name: String?

        @Option(name: .long, help: "Working directory")
        var directory: String?

        @Option(name: .long, help: "Executable to run")
        var exec: String?

        @Option(name: .long, help: "Target window id. Defaults to the focused window.")
        var window: Int?

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            var params: [String: Any] = [:]
            if let name { params["name"] = name }
            if let directory { params["directory"] = directory }
            if let exec { params["exec"] = exec }
            if let window { params["windowID"] = window }
            try IPCRun.single("createSession", params, format: format, as: SessionResponse.self)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all sessions")

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.list("listSessions", format: format, as: SessionResponse.self)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get session details")

        @Argument(help: "Session ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.single("getSession", ["id": id], format: format, as: SessionResponse.self)
        }
    }

    struct Reparent: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change the session's working directory. New tabs inherit it; existing panes keep their live CWD.")

        @Argument(help: "Session ID")
        var id: Int

        @Option(name: .long, help: "New working directory")
        var directory: String

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.single(
                "reparentSession", ["id": id, "directory": directory],
                format: format, as: SessionResponse.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a session")

        @Argument(help: "Session ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            IPCRun.fireAndForget("closeSession", ["id": id], format: format,
                                 success: "Session \(id) closed")
        }
    }
}
