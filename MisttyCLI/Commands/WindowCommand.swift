import ArgumentParser
import Foundation
import MisttyShared

struct WindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "Manage windows",
        subcommands: [
            Create.self,
            List.self,
            Get.self,
            Close.self,
            Focus.self,
        ]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new window")

        @Option(name: .long, help: "Choose the output format")
        var format = OutputFormat.detect()

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let data: Data
            do {
                data = try client.call("createWindow")
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let window = try JSONDecoder().decode(WindowResponse.self, from: data)
            formatter.print(window)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all windows")

        @Option(name: .long, help: "Choose the output format")
        var format = OutputFormat.detect()

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let data: Data
            do {
                data = try client.call("listWindows")
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let window = try JSONDecoder().decode([WindowResponse].self, from: data)
            formatter.print(window)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get window details")

        @Argument(help: "Window ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format = OutputFormat.detect()

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let data: Data
            do {
                data = try client.call("getWindow", ["id": id])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let window = try JSONDecoder().decode(WindowResponse.self, from: data)
            formatter.print(window)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a window")

        @Argument(help: "Window ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format = OutputFormat.detect()

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            do {
                _ = try client.call("closeWindow", ["id": id])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Window \(id) closed")
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Focus a window")

        @Argument(help: "Window ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format = OutputFormat.detect()

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            do {
                _ = try client.call("focusWindow", ["id": id])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Window \(id) focused")
        }
    }
}
