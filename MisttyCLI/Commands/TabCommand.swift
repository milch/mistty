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
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            var params: [String: Any] = ["sessionId": session]
            if let name { params["name"] = name }
            if let exec { params["exec"] = exec }

            let data: Data
            do {
                data = try client.call("createTab", params)
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let tab = try JSONDecoder().decode(TabResponse.self, from: data)
            formatter.print(tab)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List tabs in a session")

        @Option(name: .long, help: "Session ID")
        var session: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("listTabs", ["sessionId": session])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let tabs = try JSONDecoder().decode([TabResponse].self, from: data)
            formatter.print(tabs)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get tab details")

        @Argument(help: "Tab ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("getTab", ["id": id])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let tab = try JSONDecoder().decode(TabResponse.self, from: data)
            formatter.print(tab)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a tab")

        @Argument(help: "Tab ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            do {
                _ = try client.call("closeTab", ["id": id])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Tab \(id) closed")
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
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("renameTab", ["id": id, "name": name])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let tab = try JSONDecoder().decode(TabResponse.self, from: data)
            formatter.print(tab)
        }
    }
}
