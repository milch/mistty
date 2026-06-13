import ArgumentParser
import Foundation
import MisttyShared

struct TabCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Manage tabs",
        subcommands: [
            Create.self,
            List.self,
            Get.self,
            Close.self,
            Rename.self,
        ]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new tab")

        @Option(name: .long, help: "Session ID")
        var session: Int

        @Option(name: .long, help: "Tab name")
        var name: String?

        @Option(name: .long, help: "Executable to run")
        var exec: String?

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            var params: [String: Any] = ["sessionId": session]
            if let name { params["name"] = name }
            if let exec { params["exec"] = exec }
            try IPCRun.single("createTab", params, format: format, as: TabResponse.self)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List tabs in a session")

        @Option(name: .long, help: "Session ID")
        var session: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.list("listTabs", ["sessionId": session], format: format, as: TabResponse.self)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get tab details")

        @Argument(help: "Tab ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.single("getTab", ["id": id], format: format, as: TabResponse.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a tab")

        @Argument(help: "Tab ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            IPCRun.fireAndForget("closeTab", ["id": id], format: format,
                                 success: "Tab \(id) closed")
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a tab")

        @Argument(help: "Tab ID")
        var id: Int

        @Argument(help: "New name")
        var name: String

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.single("renameTab", ["id": id, "name": name], format: format, as: TabResponse.self)
        }
    }
}
