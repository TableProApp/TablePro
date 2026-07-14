//
//  SessionRecoveryTracker.swift
//  TablePro
//

import Foundation

@MainActor
enum SessionRecoveryTracker {
    /// Connections eligible for "Reopen Last Session". A window that never finished
    /// connecting was never activated, so a cancelled or still-connecting attempt is
    /// excluded and cannot be replayed on the next launch.
    static func connectionIds() -> [UUID] {
        RecoveryConnectionList.connectionIds(
            from: MainContentCoordinator.activeCoordinators.values.map {
                RecoveryCandidate(connectionId: $0.connectionId, isActivated: $0.isActivated)
            }
        )
    }

    /// Rewrite the recovery list from the live window set. Called whenever that set
    /// changes so the file stays correct after a crash or a force quit, neither of
    /// which runs `applicationWillTerminate`.
    static func sync() {
        guard !MainContentCoordinator.isAppTerminating else { return }
        LastOpenConnectionsStorage.shared.save(connectionIds: connectionIds())
    }
}
