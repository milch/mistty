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
            let sessionId = resolveSessionId(session, formatter: formatter)
            let popupName = name ?? exec ?? "popup"
            guard let command = exec ?? name else {
                formatter.printError(
                    "Provide --name (from config) or --exec (ad-hoc command)")
                Foundation.exit(1)
            }

            let shouldCloseOnExit = closeOnExit || !keepOnExit

            try IPCRun.single(
                "openPopup",
                [
                    "sessionId": sessionId,
                    "name": popupName,
                    "exec": command,
                    "width": width,
                    "height": height,
                    "closeOnExit": shouldCloseOnExit,
                ],
                format: format, as: PopupResponse.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a popup window")

        @Argument(help: "Popup ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            IPCRun.fireAndForget("closePopup", ["popupId": id], format: format,
                                 success: "Popup \(id) closed")
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
            let sessionId = resolveSessionId(session, formatter: formatter)

            let data = IPCRun.call(
                "togglePopup", ["sessionId": sessionId, "name": name], formatter: formatter)

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
            let sessionId = resolveSessionId(session, formatter: formatter)
            try IPCRun.list(
                "listPopups", ["sessionId": sessionId], format: format, as: PopupResponse.self)
        }
    }
}

/// Resolve session ID: use provided value or look up the first (active) session.
private func resolveSessionId(_ provided: Int?, formatter: OutputFormatter) -> Int {
    if let sid = provided { return sid }
    let data = IPCRun.call("listSessions", formatter: formatter)
    guard let sessions = try? JSONDecoder().decode([SessionResponse].self, from: data),
        let first = sessions.first
    else {
        formatter.printError("No active session. Specify --session")
        Foundation.exit(1)
    }
    return first.id
}
