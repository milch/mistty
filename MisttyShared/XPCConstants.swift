import Foundation

public enum MisttyXPC {
    public static let serviceName = "com.mistty.cli-service"
    public static let errorDomain = "com.mistty.error"

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
