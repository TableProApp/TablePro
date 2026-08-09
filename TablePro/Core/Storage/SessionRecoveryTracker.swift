//
//  SessionRecoveryTracker.swift
//  TablePro
//

import Foundation

@MainActor
enum SessionRecoveryTracker {
    /// Connections eligible for "Reopen Last Session": one the user actually worked in,
    /// or one whose window is still holding the intent to reach it. A cancelled attempt
    /// and a closing window are both excluded, so neither is replayed on the next launch.
    /// A connection that merely failed to reach its server is kept, because a database
    /// that was down is not a user who gave up.
    static func connectionIds() -> [UUID] {
        let activated = MainContentCoordinator.activeCoordinators.values.map {
            RecoveryCandidate(
                connectionId: $0.connectionId,
                isActivated: $0.isActivated,
                retainsRestoreIntent: false
            )
        }
        let pending = WindowManager.shared.connectionIdsRetainingRestoreIntent().map {
            RecoveryCandidate(connectionId: $0, isActivated: false, retainsRestoreIntent: true)
        }
        return RecoveryConnectionList.connectionIds(from: activated + pending)
    }

    /// Rewrite the recovery list from the live window set. Called whenever that set
    /// changes so the file stays correct after a crash or a force quit, neither of
    /// which runs `applicationWillTerminate`.
    static func sync() {
        guard !MainContentCoordinator.isAppTerminating else { return }
        LastOpenConnectionsStorage.shared.save(connectionIds: connectionIds())
    }
}
