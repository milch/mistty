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
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.single("createWindow", format: format, as: WindowResponse.self)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all windows")

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.list("listWindows", format: format, as: WindowResponse.self)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get window details")

        @Argument(help: "Window ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            try IPCRun.single("getWindow", ["id": id], format: format, as: WindowResponse.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a window")

        @Argument(help: "Window ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            IPCRun.fireAndForget("closeWindow", ["id": id], format: format,
                                 success: "Window \(id) closed")
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Focus a window")

        @Argument(help: "Window ID")
        var id: Int

        @Option(name: .long, help: "Choose the output format")
        var format: OutputFormat = .auto

        func run() throws {
            IPCRun.fireAndForget("focusWindow", ["id": id], format: format,
                                 success: "Window \(id) focused")
        }
    }
}
