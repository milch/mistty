import ArgumentParser
import Foundation
import MisttyShared

@main
struct MisttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mistty-cli",
        abstract: "Control Mistty terminal emulator",
        subcommands: [
            SessionCommand.self,
            TabCommand.self,
            PaneCommand.self,
            WindowCommand.self,
            PopupCommand.self,
        ]
    )
}
