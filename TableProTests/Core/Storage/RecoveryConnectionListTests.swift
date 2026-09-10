//
//  RecoveryConnectionListTests.swift
//  TableProTests
//
//  Pins #1358: "Reopen Last Session" must not replay a connection whose attempt the
//  user cancelled. It must still replay one whose server was merely unreachable,
//  which a failed restore used to erase from the list as if the user had given up.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Recovery connection list")
struct RecoveryConnectionListTests {
    @Test("A connected window is restored")
    func activatedWindowIsRestored() {
        let id = UUID()

        let ids = RecoveryConnectionList.connectionIds(
            from: [RecoveryCandidate(connectionId: id, isActivated: true, retainsRestoreIntent: false)]
        )

        #expect(ids == [id])
    }

    @Test("A cancelled connection attempt is not restored")
    func cancelledAttemptIsNotRestored() {
        let ids = RecoveryConnectionList.connectionIds(
            from: [RecoveryCandidate(connectionId: UUID(), isActivated: false, retainsRestoreIntent: false)]
        )

        #expect(ids.isEmpty)
    }

    @Test("A window whose server was unreachable is still restored")
    func failedConnectionIsStillRestored() {
        let id = UUID()

        let ids = RecoveryConnectionList.connectionIds(
            from: [RecoveryCandidate(connectionId: id, isActivated: false, retainsRestoreIntent: true)]
        )

        #expect(ids == [id])
    }

    @Test("Cancelling one connection leaves the other connected windows restorable")
    func cancelledAttemptDoesNotDropConnectedWindows() {
        let connected = UUID()
        let cancelled = UUID()

        let ids = RecoveryConnectionList.connectionIds(from: [
            RecoveryCandidate(connectionId: connected, isActivated: true, retainsRestoreIntent: false),
            RecoveryCandidate(connectionId: cancelled, isActivated: false, retainsRestoreIntent: false),
        ])

        #expect(ids == [connected])
    }

    @Test("A connection with several windows is listed once")
    func duplicateConnectionIsListedOnce() {
        let id = UUID()

        let ids = RecoveryConnectionList.connectionIds(from: [
            RecoveryCandidate(connectionId: id, isActivated: true, retainsRestoreIntent: false),
            RecoveryCandidate(connectionId: id, isActivated: true, retainsRestoreIntent: false),
        ])

        #expect(ids == [id])
    }

    @Test("An activated window and a still-pending one list the connection once")
    func activatedAndPendingListOnce() {
        let id = UUID()

        let ids = RecoveryConnectionList.connectionIds(from: [
            RecoveryCandidate(connectionId: id, isActivated: true, retainsRestoreIntent: false),
            RecoveryCandidate(connectionId: id, isActivated: false, retainsRestoreIntent: true),
        ])

        #expect(ids == [id])
    }

    @Test("A connection stays restorable while any of its windows is connected")
    func connectionSurvivesWhenOneWindowIsStillConnecting() {
        let id = UUID()

        let ids = RecoveryConnectionList.connectionIds(from: [
            RecoveryCandidate(connectionId: id, isActivated: false, retainsRestoreIntent: false),
            RecoveryCandidate(connectionId: id, isActivated: true, retainsRestoreIntent: false),
        ])

        #expect(ids == [id])
    }

    @Test("No windows means nothing to restore")
    func emptyCandidatesRestoreNothing() {
        #expect(RecoveryConnectionList.connectionIds(from: []).isEmpty)
    }
}
