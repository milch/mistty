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

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let sessionId = try resolveSessionId(session, client: client, formatter: formatter)
            let popupName = name ?? exec ?? "popup"
            guard let command = exec ?? name else {
                formatter.printError(
                    "Provide --name (from config) or --exec (ad-hoc command)")
                Foundation.exit(1)
            }

            let shouldCloseOnExit = closeOnExit || !keepOnExit

            let data: Data
            do {
                data = try client.call(
                    "openPopup",
                    [
                        "sessionId": sessionId,
                        "name": popupName,
                        "exec": command,
                        "width": width,
                        "height": height,
                        "closeOnExit": shouldCloseOnExit,
                    ])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }
            let popup = try JSONDecoder().decode(PopupResponse.self, from: data)
            formatter.print(popup)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a popup window")

        @Argument(help: "Popup ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            do {
                _ = try client.call("closePopup", ["popupId": id])
            } catch {
                formatter.printError(error.localizedDescription)
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

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let sessionId = try resolveSessionId(session, client: client, formatter: formatter)

            let data: Data
            do {
                data = try client.call("togglePopup", ["sessionId": sessionId, "name": name])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            // togglePopup may return an empty object when the popup was hidden,
            // or a PopupResponse when it became visible.
            if let popup = try? JSONDecoder().decode(PopupResponse.self, from: data) {
                formatter.print(popup)
            } else {
                formatter.printSuccess("Popup '\(name)' toggled")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List popup windows")

        @Option(name: .long, help: "Session ID (defaults to active session)")
        var session: Int?

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            let formatter = OutputFormatter(format: format)
            let client = IPCClient()
            try client.connect()

            let sessionId = try resolveSessionId(session, client: client, formatter: formatter)

            let data: Data
            do {
                data = try client.call("listPopups", ["sessionId": sessionId])
            } catch {
                formatter.printError(error.localizedDescription)
                Foundation.exit(1)
            }

            let popups = try JSONDecoder().decode([PopupResponse].self, from: data)
            formatter.print(popups)
        }
    }
}

/// Resolve session ID: use provided value or look up the first (active) session.
private func resolveSessionId(_ provided: Int?, client: IPCClient, formatter: OutputFormatter)
    throws -> Int
{
    if let sid = provided { return sid }
    let data = try client.call("listSessions")
    guard let sessions = try? JSONDecoder().decode([SessionResponse].self, from: data),
        let first = sessions.first
    else {
        formatter.printError("No active session. Specify --session")
        Foundation.exit(1)
    }
    return first.id
}
