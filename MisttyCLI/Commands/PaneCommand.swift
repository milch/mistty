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
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.createPane(tabId: tab, direction: direction) { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            guard let data = resultData else {
                OutputFormatter.printError("No response from Mistty")
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
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.listPanes(tabId: tab) { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            guard let data = resultData else {
                OutputFormatter.printError("No response from Mistty")
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
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.getPane(id: id) { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            guard let data = resultData else {
                OutputFormatter.printError("No response from Mistty")
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
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultError: Error?

            proxy.closePane(id: id) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Pane \(id) closed")
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Focus a pane")

        @Argument(help: "Pane ID")
        var id: Int

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultError: Error?

            proxy.focusPane(id: id) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Pane \(id) focused")
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
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultError: Error?

            proxy.resizePane(id: id, direction: direction, amount: amount) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
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
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.activePane { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            guard let data = resultData else {
                OutputFormatter.printError("No response from Mistty")
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
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultError: Error?

            proxy.sendKeys(paneId: pane, keys: keys) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
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
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultError: Error?

            proxy.runCommand(paneId: pane, command: command) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
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
            let client = XPCClient()
            let proxy = try client.connect()

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.getText(paneId: pane) { data, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            guard let data = resultData else {
                OutputFormatter.printError("No response from Mistty")
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
