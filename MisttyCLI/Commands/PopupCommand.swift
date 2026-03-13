import ArgumentParser
import Foundation
import MisttyShared

struct PopupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "popup",
        abstract: "Manage popup windows",
        subcommands: [
            Open.self,
            Close.self,
            Toggle.self,
            List.self,
        ]
    )

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a popup window")

        @Option(name: .long, help: "Session ID (defaults to active session)")
        var session: Int?

        @Option(name: .long, help: "Popup name")
        var name: String?

        @Option(name: .long, help: "Command to execute")
        var exec: String?

        @Option(name: .long, help: "Width as fraction of window (0.0-1.0)")
        var width: Double = 0.8

        @Option(name: .long, help: "Height as fraction of window (0.0-1.0)")
        var height: Double = 0.8

        @Flag(name: .long, help: "Close popup when process exits")
        var closeOnExit: Bool = false

        @Flag(name: .long, help: "Keep popup open when process exits")
        var keepOnExit: Bool = false

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = XPCClient()
            let proxy = try client.connect()

            let sessionId = try resolveSessionId(session, proxy: proxy)
            let popupName = name ?? exec ?? "popup"
            guard let command = exec ?? name else {
                OutputFormatter.printError("Provide --name (from config) or --exec (ad-hoc command)")
                Foundation.exit(1)
            }

            let shouldCloseOnExit = closeOnExit || !keepOnExit

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.openPopup(sessionId: sessionId, name: popupName, exec: command, width: width, height: height, closeOnExit: shouldCloseOnExit) { data, error in
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
                if let popup = try? JSONDecoder().decode(PopupResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(popup.id)"),
                        ("Name", popup.name),
                        ("Command", popup.command),
                        ("Visible", "\(popup.isVisible)"),
                        ("Pane ID", "\(popup.paneId)"),
                    ])
                }
            }
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a popup window")

        @Argument(help: "Popup ID")
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

            proxy.closePopup(popupId: id) { _, error in
                resultError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = resultError {
                OutputFormatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            formatter.printSuccess("Popup \(id) closed")
        }
    }

    struct Toggle: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Toggle a named popup")

        @Argument(help: "Popup name (from config)")
        var name: String

        @Option(name: .long, help: "Session ID (defaults to active session)")
        var session: Int?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = XPCClient()
            let proxy = try client.connect()

            let sessionId = try resolveSessionId(session, proxy: proxy)

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.togglePopup(sessionId: sessionId, name: name) { data, error in
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
                if let popup = try? JSONDecoder().decode(PopupResponse.self, from: data) {
                    formatter.printSingle([
                        ("ID", "\(popup.id)"),
                        ("Name", popup.name),
                        ("Visible", "\(popup.isVisible)"),
                    ])
                } else {
                    formatter.printSuccess("Popup '\(name)' toggled")
                }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List popup windows")

        @Option(name: .long, help: "Session ID (defaults to active session)")
        var session: Int?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Output as human-readable text")
        var human = false

        func run() throws {
            let format = OutputFormat.detect(forceJSON: json, forceHuman: human)
            let formatter = OutputFormatter(format: format)
            let client = XPCClient()
            let proxy = try client.connect()

            let sessionId = try resolveSessionId(session, proxy: proxy)

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?

            proxy.listPopups(sessionId: sessionId) { data, error in
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
                if let popups = try? JSONDecoder().decode([PopupResponse].self, from: data) {
                    let rows = popups.map { p in
                        ["\(p.id)", p.name, p.command, p.isVisible ? "visible" : "hidden", "\(p.paneId)"]
                    }
                    formatter.printTable(
                        headers: ["ID", "NAME", "COMMAND", "STATUS", "PANE"],
                        rows: rows
                    )
                }
            }
        }
    }
}

/// Resolve session ID: use provided value or look up the first (active) session.
private func resolveSessionId(_ provided: Int?, proxy: MisttyServiceProtocol) throws -> Int {
    if let sid = provided { return sid }
    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    proxy.listSessions { data, _ in
        resultData = data
        semaphore.signal()
    }
    semaphore.wait()
    guard let data = resultData,
          let sessions = try? JSONDecoder().decode([SessionResponse].self, from: data),
          let first = sessions.first
    else {
        OutputFormatter.printError("No active session. Specify --session")
        Foundation.exit(1)
    }
    return first.id
}
