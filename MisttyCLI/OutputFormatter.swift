import Foundation

enum OutputFormat {
    case human
    case json

    static func detect(forceJSON: Bool, forceHuman: Bool) -> OutputFormat {
        if forceJSON { return .json }
        if forceHuman { return .human }
        return isatty(STDOUT_FILENO) != 0 ? .human : .json
    }
}

struct OutputFormatter {
    let format: OutputFormat

    init(format: OutputFormat) {
        self.format = format
    }

    func printJSON(_ data: Data) {
        // Pretty-print the JSON
        if let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: jsonObject,
               options: [.prettyPrinted, .sortedKeys]
           ),
           let string = String(data: pretty, encoding: .utf8)
        {
            print(string)
        } else if let raw = String(data: data, encoding: .utf8) {
            print(raw)
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
        print(headerLine)

        // Print separator
        let separator = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")
        print(separator)

        // Print rows
        for row in rows {
            let line = row.enumerated().map { i, cell in
                let width = i < widths.count ? widths[i] : cell.count
                return cell.padding(toLength: width, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            print(line)
        }
    }

    func printSingle(_ pairs: [(String, String)]) {
        guard !pairs.isEmpty else { return }
        let maxKey = pairs.map { $0.0.count }.max() ?? 0
        for (key, value) in pairs {
            let paddedKey = key.padding(toLength: maxKey, withPad: " ", startingAt: 0)
            print("\(paddedKey)  \(value)")
        }
    }

    func printSuccess(_ message: String) {
        switch format {
        case .human:
            print(message)
        case .json:
            print("{}")
        }
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }
}
