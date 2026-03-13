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
        ]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new session")

        @Option(name: .long, help: "Session name")
        var name: String = "Default"

        @Option(name: .long, help: "Working directory")
        var directory: String?

        @Option(name: .long, help: "Executable to run")
        var exec: String?

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

            proxy.createSession(name: name, directory: directory, exec: exec) { data, error in
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
                if let session = try? JSONDecoder().decode(SessionResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(session.id)"),
                        ("Name", session.name),
                        ("Directory", session.directory),
                        ("Tabs", "\(session.tabCount)"),
                    ])
                }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all sessions")

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

            proxy.listSessions { data, error in
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
                if let sessions = try? JSONDecoder().decode([SessionResponse].self, from: data) {
                    let rows = sessions.map { s in
                        ["\(s.id)", s.name, s.directory, "\(s.tabCount)"]
                    }
                    formatter.printTable(
                        headers: ["ID", "NAME", "DIRECTORY", "TABS"],
                        rows: rows
                    )
                }
            }
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get session details")

        @Argument(help: "Session ID")
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

            proxy.getSession(id: id) { data, error in
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
                if let session = try? JSONDecoder().decode(SessionResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(session.id)"),
                        ("Name", session.name),
                        ("Directory", session.directory),
                        ("Tabs", "\(session.tabCount)"),
                        ("Tab IDs", session.tabIds.map { "\($0)" }.joined(separator: ", ")),
                    ])
                }
            }
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a session")

        @Argument(help: "Session ID")
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

            proxy.closeSession(id: id) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Session \(id) closed")
        }
    }
}
