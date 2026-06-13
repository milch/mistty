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
            var params: [String: Any] = ["tabId": tab]
            if let direction { params["direction"] = direction }
            try IPCRun.single("createPane", params, format: format, as: PaneResponse.self)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List panes in a tab")

        @Option(name: .long, help: "Tab ID")
        var tab: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.list("listPanes", ["tabId": tab], format: format, as: PaneResponse.self)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get pane details")

        @Argument(help: "Pane ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.single("getPane", ["id": id], format: format, as: PaneResponse.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a pane")

        @Argument(help: "Pane ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            IPCRun.fireAndForget("closePane", ["id": id], format: format,
                                 success: "Pane \(id) closed")
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
            if let direction {
                try IPCRun.single(
                    "focusPaneByDirection", ["direction": direction, "sessionId": session],
                    format: format, as: PaneResponse.self)
            } else if let id {
                try IPCRun.single("focusPane", ["id": id], format: format, as: PaneResponse.self)
            } else {
                // Should not reach here due to validate()
                OutputFormatter(format: format).printError("Provide either a pane ID or --direction")
                Foundation.exit(1)
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

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            IPCRun.fireAndForget(
                "resizePane", ["id": id, "direction": direction, "amount": amount],
                format: format, success: "Pane \(id) resized")
        }
    }

    struct Active: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get the active pane")

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.single("activePane", format: format, as: PaneResponse.self)
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
            IPCRun.fireAndForget(
                "sendKeys", ["paneId": pane, "keys": keys], format: format,
                success: "Keys sent")
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
            IPCRun.fireAndForget(
                "runCommand", ["paneId": pane, "command": command], format: format,
                success: "Command sent")
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
            try IPCRun.single("getText", ["paneId": pane], format: format,
                              as: GetTextResponse.self, printHeader: false)
        }
    }
}
