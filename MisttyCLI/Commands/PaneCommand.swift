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

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            var params: [String: Any] = ["tabId": tab]
            if let direction { params["direction"] = direction }

            let data: Data
            do {
                data = try client.call("createPane", params)
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let pane = try JSONDecoder().decode(PaneResponse.self, from: data)
            formatter.print(pane)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List panes in a tab")

        @Option(name: .long, help: "Tab ID")
        var tab: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("listPanes", ["tabId": tab])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let panes = try JSONDecoder().decode([PaneResponse].self, from: data)
            formatter.print(panes)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get pane details")

        @Argument(help: "Pane ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("getPane", ["id": id])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let pane = try JSONDecoder().decode(PaneResponse.self, from: data)
            formatter.print(pane)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a pane")

        @Argument(help: "Pane ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            do {
                _ = try client.call("closePane", ["id": id])
            } catch {
                formatter.printError(error.localizedDescription)
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

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func validate() throws {
            if id == nil && direction == nil {
                throw ValidationError("Provide either a pane ID or --direction")
            }
        }

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                if let direction {
                    data = try client.call(
                        "focusPaneByDirection", ["direction": direction, "sessionId": session])
                } else if let id {
                    data = try client.call("focusPane", ["id": id])
                } else {
                    // Should not reach here due to validate()
                    formatter.printError("Provide either a pane ID or --direction")
                    Foundation.exit(1)
                }
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let pane = try JSONDecoder().decode(PaneResponse.self, from: data)
            formatter.print(pane)
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

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            do {
                _ = try client.call(
                    "resizePane", ["id": id, "direction": direction, "amount": amount])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Pane \(id) resized")
        }
    }

    struct Active: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get the active pane")

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("activePane")
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let pane = try JSONDecoder().decode(PaneResponse.self, from: data)
            formatter.print(pane)
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

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            do {
                _ = try client.call("sendKeys", ["paneId": pane, "keys": keys])
            } catch {
                formatter.printError(error.localizedDescription)
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

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            do {
                _ = try client.call("runCommand", ["paneId": pane, "command": command])
            } catch {
                formatter.printError(error.localizedDescription)
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

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.ensureReachable()

            let data: Data
            do {
                data = try client.call("getText", ["paneId": pane])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            // Print the raw data/text
            let text = try JSONDecoder().decode(GetTextResponse.self, from: data)
            formatter.print(text, printHeader: false)
        }
    }
}
