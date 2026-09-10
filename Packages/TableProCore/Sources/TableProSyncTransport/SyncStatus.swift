import Foundation

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case error(SyncError)
    case disabled(DisableReason)

    public var isSyncing: Bool {
        self == .syncing
    }

    public var isEnabled: Bool {
        switch self {
        case .disabled:
            return false
        default:
            return true
        }
    }
}

public enum DisableReason: Equatable, Sendable {
    case noAccount
    case licenseRequired
    case licenseExpired

    /// A license this Mac holds but has not confirmed with the server inside the grace period.
    /// Separate from `licenseRequired` because the way out is the network, not a purchase, and
    /// offering to activate a license the person already owns is the one thing that cannot help.
    case licenseUnverified
    case userDisabled
}
