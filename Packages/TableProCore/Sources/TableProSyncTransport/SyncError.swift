import CloudKit
import Foundation

public enum SyncError: Error, LocalizedError, Equatable, Sendable {
    case networkUnavailable
    case accountUnavailable
    case quotaExceeded
    case zoneNotFound
    case serverError(String)
    case conflictDetected
    case encodingFailed(String)
    case pushRejected(count: Int, detail: String)
    case tokenExpired
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return String(localized: "Network is unavailable. Changes will sync when connectivity is restored.")
        case .accountUnavailable:
            return String(localized: "iCloud account is not available. Sign in to iCloud in System Settings.")
        case .quotaExceeded:
            return String(localized: "iCloud storage is full. Free up space in iCloud and try again.")
        case .zoneNotFound:
            return String(localized: "Sync zone not found. A full sync will be performed.")
        case .serverError(let message):
            return String(format: String(localized: "iCloud server error: %@"), message)
        case .conflictDetected:
            return String(localized: "A sync conflict was detected and needs to be resolved.")
        case .encodingFailed(let detail):
            return String(format: String(localized: "Failed to encode sync data: %@"), detail)
        case .pushRejected(let count, let detail):
            return String(
                format: String(localized: "iCloud rejected %d change(s). They stay on this device and will retry: %@"),
                count,
                detail
            )
        case .tokenExpired:
            return String(localized: "Sync token expired. A full sync will be performed.")
        case .unknown(let message):
            return String(format: String(localized: "An unknown sync error occurred: %@"), message)
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
