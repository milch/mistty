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

            proxy.createWindow { data, error in
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
                if let window = try? JSONDecoder().decode(WindowResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(window.id)"),
                        ("Sessions", "\(window.sessionCount)"),
                    ])
                }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all windows")

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

            proxy.listWindows { data, error in
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
                if let windows = try? JSONDecoder().decode([WindowResponse].self, from: data) {
                    let rows = windows.map { w in
                        ["\(w.id)", "\(w.sessionCount)"]
                    }
                    formatter.printTable(
                        headers: ["ID", "SESSIONS"],
                        rows: rows
                    )
                }
            }
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get window details")

        @Argument(help: "Window ID")
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

            proxy.getWindow(id: id) { data, error in
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
                if let window = try? JSONDecoder().decode(WindowResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(window.id)"),
                        ("Sessions", "\(window.sessionCount)"),
                    ])
                }
            }
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a window")

        @Argument(help: "Window ID")
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

            proxy.closeWindow(id: id) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Window \(id) closed")
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Focus a window")

        @Argument(help: "Window ID")
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

            proxy.focusWindow(id: id) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Window \(id) focused")
        }
    }
}
