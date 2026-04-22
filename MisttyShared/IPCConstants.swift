import Foundation

public enum MisttyIPC {
    public static let serviceName = "com.mistty.cli-service"
    public static let errorDomain = "com.mistty.error"

    /// Env var the main app sets on spawned shells so `mistty-cli` from inside
    /// a Mistty pane always talks back to the *same* Mistty instance, even
    /// when both dev and release builds are running.
    public static let socketPathEnvVar = "MISTTY_SOCKET"

    /// Path the app binds its listener to. Always bundle-path derived —
    /// never the env var, so launching the dev app from a shell whose env
    /// happens to contain `MISTTY_SOCKET` from a release instance doesn't
    /// make the dev app try to bind the release socket.
    public static var serverSocketPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Mistty/mistty\(buildVariantSuffix()).sock").path
    }

    /// Path the CLI connects to. Prefers the env var (set by the main app on
    /// every spawned shell) so a CLI call from inside a Mistty pane reaches
    /// *that* instance even when both dev and release are running. Falls
    /// back to the bundle-path-derived default for CLI invocations from
    /// outside any Mistty shell.
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment[socketPathEnvVar],
           !override.isEmpty {
            return override
        }
        return serverSocketPath
    }

    /// Returns `-dev` when this binary is running from inside a `Mistty-dev.app`
    /// bundle, empty otherwise. Lets dev and release builds bind to distinct
    /// sockets so their CLIs don't stomp on each other when both apps are
    /// running. The CLI bundled inside each `.app` resolves the same suffix
    /// by walking up its own executable path, so release CLI → release socket,
    /// dev CLI → dev socket.
    private static func buildVariantSuffix() -> String {
        buildVariantSuffix(forExecutablePath: Bundle.main.executablePath)
    }

    /// Pure implementation, exposed for unit tests.
    internal static func buildVariantSuffix(forExecutablePath executable: String?) -> String {
        guard let executable else { return "" }
        var path = executable as NSString
        while path.length > 1 {
            let last = path.lastPathComponent
            if last.hasSuffix(".app") {
                let name = (last as NSString).deletingPathExtension
                return name == "Mistty-dev" ? "-dev" : ""
            }
            path = path.deletingLastPathComponent as NSString
        }
        return ""
    }

    public static let maxMessageSize: UInt32 = 16 * 1024 * 1024  // 16 MB

    public enum ErrorCode: Int {
        case entityNotFound = 1
        case invalidArgument = 2
        case operationFailed = 3
    }

    public static func error(_ code: ErrorCode, _ message: String) -> NSError {
        NSError(
            domain: errorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
