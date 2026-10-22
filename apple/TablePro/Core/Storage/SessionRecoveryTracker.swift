//
//  SessionRecoveryTracker.swift
//  TablePro
//

import Foundation

@MainActor
enum SessionRecoveryTracker {
    private static let storage: LastOpenConnectionsStorage? = AppStorageEnvironment.shared.isUnitTestHost ? nil : .shared

    static func lastSession() -> LastSession {
        let activated = Set(
            MainContentCoordinator.activeCoordinators.values.filter(\.isActivated).map(\.connectionId)
        )
        let candidates = WindowManager.shared.hostedWorkspaces().map {
            RecoveryCandidate(
                connectionId: $0.connectionId,
                openedAt: $0.openedAt,
                phase: $0.phase,
                isActivated: activated.contains($0.connectionId)
            )
        }
        return RecoveryConnectionList.lastSession(
            from: candidates,
            endedByUser: wasEndedByUser,
            shownConnectionId: WindowManager.shared.shownConnectionId()
        )
    }

    // A native tab AppKit joined but never displayed keeps the phase it was born with, so a stale
    // `.connected` there must not redial a session the user ended. The flag clears on the next connect.
    private static func wasEndedByUser(_ connectionId: UUID) -> Bool {
        guard DatabaseManager.shared.wasDisconnectedByUser(connectionId) else { return false }
        return DatabaseManager.shared.activeSessions[connectionId] == nil
    }

    // Kept current on every change because a crash or force quit never runs `applicationWillTerminate`.
    static func sync() {
        guard !MainContentCoordinator.isAppTerminating, let storage else { return }
        storage.save(lastSession())
    }

    static func saveOnQuit() {
        guard let storage else { return }
        let session = lastSession()
        if RecoveryConnectionList.shouldSaveOnQuit(session, origin: AppActivationPolicyController.shared.origin) {
            storage.save(session)
        }
        storage.seal()
    }
}
