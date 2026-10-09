import Foundation

/// What asked for a sync. The same request means different things depending on what stopped the
/// last run, so each trigger is named rather than collapsed into "sync now".
public enum SyncTrigger: Equatable, Sendable {
    /// Sync starts over: the app launched, or a license began covering it again.
    case launch
    /// The app came forward, or the system woke it to refresh.
    case activation
    /// Something synced was edited on this device.
    case localChange
    /// `CKAccountChanged`: the person signed in or out, or the account became ready.
    case accountChange
    /// The network came back after a run that could not reach iCloud.
    case networkRestored
    /// The wait a held-back run asked for has passed.
    case scheduledRetry
    /// The person asked: Sync Now, Try Again, pull to refresh, turning sync on.
    case userRequest
}

/// How much of a run a trigger may start.
public enum SyncAdmission: Equatable, Sendable {
    case full
    /// Download what other devices sent, but hold this device's changes back.
    case downloadOnly
    case none

    /// Decides whether `trigger` may start a run, given how the last one ended.
    ///
    /// A condition a retry cannot clear keeps the automatic triggers from resending every pending
    /// change: an edit, an activation and a network change do not fix full storage or a signed-out
    /// account. What can is the wait running out, the account changing, or the person asking.
    public static func decide(
        for trigger: SyncTrigger,
        after error: SyncError?,
        nextAttempt: Date?,
        now: Date = Date()
    ) -> SyncAdmission {
        let isDue = nextAttempt.map { now >= $0 } ?? true
        switch error {
        case nil, .offline, .recordsRejected, .pullNotSaved, .unexpected:
            return .full
        case .busy:
            if trigger == .userRequest || trigger == .accountChange { return .full }
            return isDue ? .full : .none
        case .blocked(let blocker):
            return decide(for: trigger, blockedBy: blocker, isDue: isDue)
        }
    }

    private static func decide(for trigger: SyncTrigger, blockedBy blocker: SyncBlocker, isDue: Bool) -> SyncAdmission {
        switch blocker {
        case .storageFull:
            switch trigger {
            case .launch, .accountChange, .scheduledRetry, .userRequest:
                return .full
            case .localChange:
                return isDue ? .full : .none
            case .activation, .networkRestored:
                return isDue ? .full : .downloadOnly
            }
        case .signedOut, .accountNotReady, .accountRestricted:
            /// The run starts by reading the account status, which is local and cheap, so every
            /// trigger but an edit may look again.
            return trigger == .localChange ? .none : .full
        case .dataDeletedFromICloud:
            /// Uploading again is the person's call, made through its own action, never a trigger.
            /// A download still looks for the zone, which another device may have brought back.
            return trigger == .localChange ? .none : .downloadOnly
        case .appUpdateRequired, .unavailable:
            return trigger == .launch || trigger == .userRequest ? .full : .none
        }
    }
}
