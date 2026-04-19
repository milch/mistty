import ArgumentParser
import Foundation
import MisttyShared

enum OutputFormat: ExpressibleByArgument {
    init?(argument: String) {
        switch argument {
        case "json": self = .json
        case "human": self = .human
        case "quiet": self = .quiet
        default: return nil
        }
    }
    case human
    case json
    case quiet

    static func detect() -> OutputFormat {
        return isatty(STDOUT_FILENO) == 0 ? .json : .human
    }
}

struct GenericData: Codable {
    let text: String
}

struct OutputFormatter {
    let format: OutputFormat
    let encoder = JSONEncoder()

    init(format: OutputFormat) {
        self.format = format
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func print(_ data: Data) {
        switch format {
        case .human:
            // In human mode, just print the text directly
            if let text = String(data: data, encoding: .utf8) {
                Swift.print(text)
            }
            break
        case .json:
            printJSON(GenericData(text: String(data: data, encoding: .utf8) ?? ""))
            break
        case .quiet: break
        }
    }

    func print<T: PrintableByFormatter & Codable>(_ item: T) {
        switch format {
        case .human:
            let header = T.formatHeader()
            let row = item.formatRow()
            printSingle(zip(header, row).map { ($0.0, $0.1) })
            break
        case .json:
            printJSON(item)
            break
        case .quiet: break
        }
    }

    func print<T: PrintableByFormatter & Codable>(_ item: [T]) {
        switch format {
        case .human:
            let header = T.formatHeader()
            let rows = item.map { $0.formatRow() }
            printTable(headers: header, rows: rows)
            break
        case .json:
            printJSON(item)
            break
        case .quiet: break
        }
    }

    func printJSON(_ item: Codable) {
        if let pretty = try? encoder.encode(item),
            let string = String(data: pretty, encoding: .utf8)
        {
            Swift.print(string)
        } else {
            Swift.print(item)
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
        case .quiet: break
        }
    }

    func printError(_ message: String) {
        if format != .quiet {
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        }
    }
}
