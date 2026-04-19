import ArgumentParser
import Foundation
import MisttyShared

enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
    case auto
    case human
    case json
    case quiet
}

struct OutputFormatter {
    let format: OutputFormat
    let encoder = JSONEncoder()

    init(format: OutputFormat) {
        self.format = Self.resolve(format)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    /// Resolve `.auto` against the current stdout TTY state. Non-TTY → JSON, TTY → human.
    private static func resolve(_ format: OutputFormat) -> OutputFormat {
        guard format == .auto else { return format }
        return isatty(STDOUT_FILENO) == 0 ? .json : .human
    }

    func print<T: PrintableByFormatter & Codable>(_ item: T, printHeader: Bool = true) {
        switch format {
        case .human:
            let row = item.formatRow()
            if printHeader {
                let header = T.formatHeader()
                assert(header.count == row.count, "\(T.self) header/row column count mismatch")
                printSingle(Array(zip(header, row)))
            } else {
                Swift.print(row.joined(separator: "  "))
            }
        case .json:
            printJSON(item)
        case .quiet, .auto:
            break
        }
    }

    func print<T: PrintableByFormatter & Codable>(_ items: [T]) {
        switch format {
        case .human:
            let header = T.formatHeader()
            let rows = items.map { $0.formatRow() }
            for row in rows {
                assert(header.count == row.count, "\(T.self) header/row column count mismatch")
            }
            printTable(headers: header, rows: rows)
        case .json:
            printJSON(items)
        case .quiet, .auto:
            break
        }
    }

    func printJSON(_ item: Codable) {
        do {
            let data = try encoder.encode(item)
            guard let string = String(data: data, encoding: .utf8) else {
                FileHandle.standardError.write(
                    Data("Error: encoded JSON was not valid UTF-8\n".utf8))
                Foundation.exit(1)
            }
            Swift.print(string)
        } catch {
            FileHandle.standardError.write(
                Data("Error: failed to encode response as JSON: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    func printTable(headers: [String], rows: [[String]]) {
        guard !headers.isEmpty else { return }

        // Calculate column widths
        var widths = headers.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        // Print header
        let headerLine = headers.enumerated().map { i, h in
            h.padding(toLength: widths[i], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
        Swift.print(headerLine)

        // Print separator
        let separator = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")
        Swift.print(separator)

        // Print rows
        for row in rows {
            let line = row.enumerated().map { i, cell in
                let width = i < widths.count ? widths[i] : cell.count
                return cell.padding(toLength: width, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            Swift.print(line)
        }
    }

    func printSingle(_ pairs: [(String, String)]) {
        guard !pairs.isEmpty else { return }
        let maxKey = pairs.map { $0.0.count }.max() ?? 0
        for (key, value) in pairs {
            let paddedKey = key.padding(toLength: maxKey, withPad: " ", startingAt: 0)
            Swift.print("\(paddedKey)  \(value)")
        }
    }

    func printSuccess(_ message: String) {
        switch format {
        case .human:
            Swift.print(message)
        case .json:
            Swift.print("{}")
        case .quiet, .auto:
            break
        }
    }

    func printError(_ message: String) {
        if format != .quiet {
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        }
    }
}
