import Foundation

public enum DatabaseAccessError: Error, Sendable {
    case notConnected(UUID)
    case invalidArgument(String)
    case forbidden(String, context: [String: String]? = nil)
    case timeout(String, context: [String: String]? = nil)
    case notFound(String)
    case expired(String)
    case userCancelled
    case dataSourceError(String)
    // The caller stopped waiting while a write it sent was in the driver, so the write may have been applied.
    case stoppedWhileRunning(String)

    public var message: String {
        switch self {
        case .notConnected(let connectionId):
            "Not connected: \(connectionId)"
        case .invalidArgument(let detail):
            "Invalid argument: \(detail)"
        case .forbidden(let detail, _):
            "Forbidden: \(detail)"
        case .timeout(let detail, _):
            "Timeout: \(detail)"
        case .notFound(let detail):
            "Not found: \(detail)"
        case .expired(let detail):
            "Expired: \(detail)"
        case .userCancelled:
            "User cancelled"
        case .dataSourceError(let detail):
            "Data source error: \(detail)"
        case .stoppedWhileRunning(let detail):
            detail
        }
    }

    var isUserCancelled: Bool {
        if case .userCancelled = self { return true }
        return false
    }
}

extension DatabaseAccessError: LocalizedError {
    public var errorDescription: String? { message }
}
