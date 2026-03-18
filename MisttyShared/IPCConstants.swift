import Foundation

public enum MisttyIPC {
    public static let serviceName = "com.mistty.cli-service"
    public static let errorDomain = "com.mistty.error"

    public static var socketPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Mistty/mistty.sock").path
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
