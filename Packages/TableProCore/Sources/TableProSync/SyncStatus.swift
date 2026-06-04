public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case error(SyncError)
    case disabled(SyncDisableReason)

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

public enum SyncDisableReason: Equatable, Sendable {
    case noAccount
    case licenseRequired
    case licenseExpired
    case userDisabled
}
