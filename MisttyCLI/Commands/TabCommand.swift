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

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            var params: [String: Any] = ["sessionId": session]
            if let name { params["name"] = name }
            if let exec { params["exec"] = exec }

            let data: Data
            do {
                data = try client.call("createTab", params)
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let tab = try? JSONDecoder().decode(TabResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(tab.id)"),
                        ("Title", tab.title),
                        ("Panes", "\(tab.paneCount)"),
                    ])
                }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List tabs in a session")

        @Option(name: .long, help: "Session ID")
        var session: Int

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let data: Data
            do {
                data = try client.call("listTabs", ["sessionId": session])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let tabs = try? JSONDecoder().decode([TabResponse].self, from: data) {
                    let rows = tabs.map { t in
                        ["\(t.id)", t.title, "\(t.paneCount)"]
                    }
                    formatter.printTable(
                        headers: ["ID", "TITLE", "PANES"],
                        rows: rows
                    )
                }
            }
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get tab details")

        @Argument(help: "Tab ID")
        var id: Int

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let data: Data
            do {
                data = try client.call("getTab", ["id": id])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let tab = try? JSONDecoder().decode(TabResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(tab.id)"),
                        ("Title", tab.title),
                        ("Panes", "\(tab.paneCount)"),
                        ("Pane IDs", tab.paneIds.map { "\($0)" }.joined(separator: ", ")),
                    ])
                }
            }
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a tab")

        @Argument(help: "Tab ID")
        var id: Int

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            do {
                _ = try client.call("closeTab", ["id": id])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
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

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let data: Data
            do {
                data = try client.call("renameTab", ["id": id, "name": name])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let tab = try? JSONDecoder().decode(TabResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(tab.id)"),
                        ("Title", tab.title),
                        ("Panes", "\(tab.paneCount)"),
                    ])
                }
            }
        }
    }
}
