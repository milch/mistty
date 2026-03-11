import Foundation

struct SSHHost: Sendable {
    let alias: String
    let hostname: String?
}

struct SSHConfigService {
    static func parse(_ content: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var currentAlias: String?
        var currentHostname: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if lower.hasPrefix("host ") {
                if let alias = currentAlias, !alias.contains("*") {
                    hosts.append(SSHHost(alias: alias, hostname: currentHostname))
                }
                currentAlias = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                currentHostname = nil
            } else if lower.hasPrefix("hostname ") {
                currentHostname = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            }
        }

        if let alias = currentAlias, !alias.contains("*") {
            hosts.append(SSHHost(alias: alias, hostname: currentHostname))
        }

        return hosts
    }

    static func loadHosts() -> [SSHHost] {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let content = try? String(contentsOf: url) else { return [] }
        return parse(content)
    }
}
