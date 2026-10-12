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

    /// The outcome the next trigger is judged against. Nil while nothing stands in the way.
    public var error: SyncError? {
        guard case .error(let error) = self else { return nil }
        return error
    }
}

/// Why sync is off by the person's choice or their license. A condition of the iCloud account is
/// not one of these: sync stays on and waits for it as `SyncError.blocked`.
public enum DisableReason: Equatable, Sendable {
    case licenseRequired
    case licenseExpired

    /// A license this Mac holds but has not confirmed with the server inside the grace period.
    /// Separate from `licenseRequired` because the way out is the network, not a purchase, and
    /// offering to activate a license the person already owns is the one thing that cannot help.
    case licenseUnverified
    case userDisabled
}
