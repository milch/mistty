import ArgumentParser
import Foundation
import MisttyShared

struct PaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Manage panes",
        subcommands: [
            Create.self,
            List.self,
            Get.self,
            Close.self,
            Focus.self,
            Resize.self,
            Active.self,
            SendKeys.self,
            RunCommand.self,
            GetText.self,
        ]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new pane")

        @Option(name: .long, help: "Tab ID")
        var tab: Int

        @Option(name: .long, help: "Split direction (horizontal or vertical)")
        var direction: String?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            var params: [String: Any] = ["tabId": tab]
            if let direction { params["direction"] = direction }

            let data: Data
            do {
                data = try client.call("createPane", params)
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let pane = try? JSONDecoder().decode(PaneResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(pane.id)"),
                        ("Directory", pane.directory ?? "-"),
                    ])
                }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List panes in a tab")

        @Option(name: .long, help: "Tab ID")
        var tab: Int

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
                data = try client.call("listPanes", ["tabId": tab])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let panes = try? JSONDecoder().decode([PaneResponse].self, from: data) {
                    let rows = panes.map { p in
                        ["\(p.id)", p.directory ?? "-"]
                    }
                    formatter.printTable(
                        headers: ["ID", "DIRECTORY"],
                        rows: rows
                    )
                }
            }
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get pane details")

        @Argument(help: "Pane ID")
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
                data = try client.call("getPane", ["id": id])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let pane = try? JSONDecoder().decode(PaneResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(pane.id)"),
                        ("Directory", pane.directory ?? "-"),
                    ])
                }
            }
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a pane")

        @Argument(help: "Pane ID")
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
                _ = try client.call("closePane", ["id": id])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Pane \(id) closed")
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Focus a pane")

        @Argument(help: "Pane ID (omit when using --direction)")
        var id: Int?

        @Option(name: .long, help: "Focus direction (left, right, up, down)")
        var direction: String?

        @Option(name: .long, help: "Session ID for direction-based focus (0 = active)")
        var session: Int = 0

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func validate() throws {
            if id == nil && direction == nil {
                throw ValidationError("Provide either a pane ID or --direction")
            }
        }

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let data: Data
            do {
                if let direction {
                    data = try client.call("focusPaneByDirection", ["direction": direction, "sessionId": session])
                } else if let id {
                    data = try client.call("focusPane", ["id": id])
                } else {
                    // Should not reach here due to validate()
                    OutputFormatter.printError("Provide either a pane ID or --direction")
                    Foundation.exit(1)
                }
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let pane = try? JSONDecoder().decode(PaneResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(pane.id)"),
                        ("Directory", pane.directory ?? "-"),
                    ])
                } else {
                    formatter.printSuccess("Pane focused")
                }
            }
        }
    }

    struct Resize: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resize a pane")

        @Argument(help: "Pane ID")
        var id: Int

        @Option(name: .long, help: "Resize direction (up, down, left, right)")
        var direction: String

        @Option(name: .long, help: "Amount to resize")
        var amount: Int = 1

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
                _ = try client.call("resizePane", ["id": id, "direction": direction, "amount": amount])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Pane \(id) resized")
        }
    }

    struct Active: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get the active pane")

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
                data = try client.call("activePane")
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                if let pane = try? JSONDecoder().decode(PaneResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(pane.id)"),
                        ("Directory", pane.directory ?? "-"),
                    ])
                }
            }
        }
    }

    struct SendKeys: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "send-keys",
            abstract: "Send keys to a pane"
        )

        @Argument(help: "Keys to send")
        var keys: String

        @Option(name: .long, help: "Pane ID (0 = active pane)")
        var pane: Int = 0

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
                _ = try client.call("sendKeys", ["paneId": pane, "keys": keys])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Keys sent")
        }
    }

    struct RunCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run-command",
            abstract: "Run a command in a pane"
        )

        @Argument(help: "Command to run")
        var command: String

        @Option(name: .long, help: "Pane ID (0 = active pane)")
        var pane: Int = 0

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
                _ = try client.call("runCommand", ["paneId": pane, "command": command])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Command sent")
        }
    }

    struct GetText: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-text",
            abstract: "Get text content from a pane"
        )

        @Option(name: .long, help: "Pane ID (0 = active pane)")
        var pane: Int = 0

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
                data = try client.call("getText", ["paneId": pane])
            } catch {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            switch format {
            case .json:
                formatter.printJSON(data)
            case .human:
                // In human mode, just print the text directly
                if let text = String(data: data, encoding: .utf8) {
                    print(text)
                }
            }
        }
    }
}
