import Foundation
import MisttyShared

/// Shared execution scaffold for CLI subcommands. Every subcommand used to
/// repeat the same ritual: build formatter, ensure the app is reachable,
/// call, print-error-and-exit(1) on failure, decode, print. Decode errors
/// intentionally PROPAGATE (as before) so ArgumentParser reports them.
enum IPCRun {
    /// Reachability + call + print-error-and-exit. The shared trunk of all
    /// three entry points; also usable directly by subcommands with bespoke
    /// post-processing.
    static func call(
        _ method: String, _ params: [String: Any] = [:], formatter: OutputFormatter
    ) -> Data {
        let client = IPCClient()
        do {
            try client.ensureReachable()
            return try client.call(method, params)
        } catch {
            formatter.printError(error.localizedDescription)
            Foundation.exit(exitCode(for: error))
        }
    }

    /// Distinct exit codes so scripts can branch without parsing stderr:
    /// 2 = entity not found, 3 = invalid argument, 1 = everything else
    /// (connection failures, legacy plain-text errors, operationFailed).
    static func exitCode(for error: Error) -> Int32 {
        guard case IPCClientError.remoteCoded(let code, _) = error else { return 1 }
        switch code {
        case .entityNotFound: return 2
        case .invalidArgument: return 3
        case .operationFailed: return 1
        }
    }

    /// Call `method` and print the decoded single response.
    static func single<T: PrintableByFormatter & Codable>(
        _ method: String, _ params: [String: Any] = [:],
        format: OutputFormat, as type: T.Type, printHeader: Bool = true
    ) throws {
        let formatter = OutputFormatter(format: format)
        let data = call(method, params, formatter: formatter)
        let item = try JSONDecoder().decode(T.self, from: data)
        formatter.print(item, printHeader: printHeader)
    }

    /// Call `method` and print the decoded array response as a table.
    static func list<T: PrintableByFormatter & Codable>(
        _ method: String, _ params: [String: Any] = [:],
        format: OutputFormat, as type: T.Type
    ) throws {
        let formatter = OutputFormatter(format: format)
        let data = call(method, params, formatter: formatter)
        let items = try JSONDecoder().decode([T].self, from: data)
        formatter.print(items)
    }

    /// Call `method`, discard the payload, print a success message.
    static func fireAndForget(
        _ method: String, _ params: [String: Any] = [:],
        format: OutputFormat, success: String
    ) {
        let formatter = OutputFormatter(format: format)
        _ = call(method, params, formatter: formatter)
        formatter.printSuccess(success)
    }
}
