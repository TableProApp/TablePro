import CloudKit
import Foundation

public enum SyncError: Error, LocalizedError, Equatable, Sendable {
    case noAccount
    case networkUnavailable
    case accountUnavailable
    case quotaExceeded
    case zoneNotFound
    case serverError(String)
    case conflictDetected
    case encodingFailed(String)
    case zoneCreationFailed(String)
    case pushFailed(String)
    case pullFailed(String)
    case tokenExpired
    case unknown(String)
    case unknownError(String)

    public var errorDescription: String? {
        switch self {
        case .noAccount:
            return String(localized: "No iCloud account available")
        case .networkUnavailable:
            return String(localized: "Network is unavailable. Changes will sync when connectivity is restored.")
        case .accountUnavailable:
            return String(localized: "iCloud account is not available. Sign in to iCloud in System Settings.")
        case .quotaExceeded:
            return String(localized: "iCloud storage is full. Free up space or reduce the history sync limit.")
        case .zoneNotFound:
            return String(localized: "Sync zone not found. A full sync will be performed.")
        case .serverError(let detail):
            return String(format: String(localized: "iCloud server error: %@"), detail)
        case .conflictDetected:
            return String(localized: "A sync conflict was detected and needs to be resolved.")
        case .encodingFailed(let detail):
            return String(format: String(localized: "Failed to encode sync data: %@"), detail)
        case .zoneCreationFailed(let detail):
            return String(format: String(localized: "Failed to create sync zone: %@"), detail)
        case .pushFailed(let detail):
            return String(format: String(localized: "Failed to push changes: %@"), detail)
        case .pullFailed(let detail):
            return String(format: String(localized: "Failed to pull changes: %@"), detail)
        case .tokenExpired:
            return String(localized: "Sync token expired, full sync required")
        case .unknown(let detail):
            return String(format: String(localized: "An unknown sync error occurred: %@"), detail)
        case .unknownError(let detail):
            return String(format: String(localized: "Sync error: %@"), detail)
        }
    }

    public static func from(_ error: Error) -> SyncError {
        if let syncError = error as? SyncError {
            return syncError
        }

        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure:
                return .networkUnavailable
            case .notAuthenticated:
                return .accountUnavailable
            case .quotaExceeded:
                return .quotaExceeded
            case .zoneNotFound:
                return .zoneNotFound
            case .changeTokenExpired:
                return .tokenExpired
            default:
                return .serverError(ckError.localizedDescription)
            }
        }

        return .unknown(error.localizedDescription)
    }
}
