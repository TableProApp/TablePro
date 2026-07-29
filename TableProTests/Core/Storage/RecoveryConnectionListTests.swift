//
//  RecoveryConnectionListTests.swift
//  TableProTests
//
//  Pins #1358: "Reopen Last Session" must not replay a connection whose attempt the
//  user cancelled. A window that never finished connecting was never activated, so
//  it is not part of the session to restore.
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
            from: [RecoveryCandidate(connectionId: id, isActivated: true)]
        )

        #expect(ids == [id])
    }

    @Test("A cancelled connection attempt is not restored")
    func cancelledAttemptIsNotRestored() {
        let ids = RecoveryConnectionList.connectionIds(
            from: [RecoveryCandidate(connectionId: UUID(), isActivated: false)]
        )

        #expect(ids.isEmpty)
    }

    @Test("Cancelling one connection leaves the other connected windows restorable")
    func cancelledAttemptDoesNotDropConnectedWindows() {
        let connected = UUID()
        let cancelled = UUID()

        let ids = RecoveryConnectionList.connectionIds(from: [
            RecoveryCandidate(connectionId: connected, isActivated: true),
            RecoveryCandidate(connectionId: cancelled, isActivated: false),
        ])

        #expect(ids == [connected])
    }

    @Test("A connection with several windows is listed once")
    func duplicateConnectionIsListedOnce() {
        let id = UUID()

        let ids = RecoveryConnectionList.connectionIds(from: [
            RecoveryCandidate(connectionId: id, isActivated: true),
            RecoveryCandidate(connectionId: id, isActivated: true),
        ])

        #expect(ids == [id])
    }

    @Test("A connection stays restorable while any of its windows is connected")
    func connectionSurvivesWhenOneWindowIsStillConnecting() {
        let id = UUID()

        let ids = RecoveryConnectionList.connectionIds(from: [
            RecoveryCandidate(connectionId: id, isActivated: false),
            RecoveryCandidate(connectionId: id, isActivated: true),
        ])

        #expect(ids == [id])
    }

    @Test("No windows means nothing to restore")
    func emptyCandidatesRestoreNothing() {
        #expect(RecoveryConnectionList.connectionIds(from: []).isEmpty)
    }
}
