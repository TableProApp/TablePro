import Foundation

public enum SyncError: Error, LocalizedError, Equatable, Sendable {
    case noAccount
    case networkUnavailable
    case zoneCreationFailed(String)
    case pushFailed(String)
    case pullFailed(String)
    case tokenExpired
    case unknownError(String)

    public var errorDescription: String? {
        switch self {
        case .noAccount:
            return String(localized: "No iCloud account available")
        case .networkUnavailable:
            return String(localized: "Network is unavailable")
        case .zoneCreationFailed(let detail):
            return String(format: String(localized: "Failed to create sync zone: %@"), detail)
        case .pushFailed(let detail):
            return String(format: String(localized: "Failed to push changes: %@"), detail)
        case .pullFailed(let detail):
            return String(format: String(localized: "Failed to pull changes: %@"), detail)
        case .tokenExpired:
            return String(localized: "Sync token expired, full sync required")
        case .unknownError(let detail):
            return String(format: String(localized: "Sync error: %@"), detail)
        }
    }
}
