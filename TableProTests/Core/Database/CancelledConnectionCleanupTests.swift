//
//  CancelledConnectionCleanupTests.swift
//  TableProTests
//
//  Pins the fix for #1358: a cancelled connection attempt must not tear down the
//  shared session entry, which after a cancel + retry belongs to the new attempt.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Cancelled connection cleanup", .serialized)
@MainActor
struct CancelledConnectionCleanupTests {
    @Test("Cancelled attempt leaves the session entry intact")
    func cancelledLeavesSessionIntact() {
        let id = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id, name: "Retry")),
            for: id
        )
        defer { DatabaseManager.shared.removeSession(for: id) }

        DatabaseManager.shared.finalizeConnectionFailure(for: id, cancelled: true)

        #expect(DatabaseManager.shared.activeSessions[id] != nil)
    }

    @Test("Genuine failure removes the session entry")
    func genuineFailureRemovesSession() {
        let id = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id, name: "Failed")),
            for: id
        )
        defer { DatabaseManager.shared.removeSession(for: id) }

        DatabaseManager.shared.finalizeConnectionFailure(for: id, cancelled: false)

        #expect(DatabaseManager.shared.activeSessions[id] == nil)
    }

    @Test("Cancelled finalize keeps currentSessionId untouched")
    func cancelledKeepsCurrentSessionId() {
        let id = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id, name: "Retry")),
            for: id
        )
        DatabaseManager.shared.currentSessionId = id
        defer {
            DatabaseManager.shared.removeSession(for: id)
            DatabaseManager.shared.currentSessionId = nil
        }

        DatabaseManager.shared.finalizeConnectionFailure(for: id, cancelled: true)

        #expect(DatabaseManager.shared.currentSessionId == id)
    }

    @Test("Genuine failure clears currentSessionId when no other session remains")
    func genuineFailureClearsCurrentSessionId() {
        let id = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id, name: "Failed")),
            for: id
        )
        DatabaseManager.shared.currentSessionId = id
        defer {
            DatabaseManager.shared.removeSession(for: id)
            DatabaseManager.shared.currentSessionId = nil
        }

        DatabaseManager.shared.finalizeConnectionFailure(for: id, cancelled: false)

        #expect(DatabaseManager.shared.currentSessionId != id)
    }

    @Test("Cancelling a pending connection invalidates the attempt still in flight")
    func cancelInvalidatesInFlightAttempt() async {
        let id = UUID()
        let attempt = DatabaseManager.shared.connectionAttempts.begin(for: id)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id, name: "Pending")),
            for: id
        )
        defer { DatabaseManager.shared.removeSession(for: id) }

        await DatabaseManager.shared.cancelEnsureConnected(id)

        #expect(!DatabaseManager.shared.connectionAttempts.isCurrent(attempt, for: id))
        #expect(DatabaseManager.shared.activeSessions[id] == nil)
    }

    @Test("Genuine failure moves currentSessionId to a remaining session")
    func genuineFailureSwitchesToRemainingSession() {
        let failedId = UUID()
        let otherId = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: failedId, name: "Failed")),
            for: failedId
        )
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: otherId, name: "Other")),
            for: otherId
        )
        DatabaseManager.shared.currentSessionId = failedId
        defer {
            DatabaseManager.shared.removeSession(for: failedId)
            DatabaseManager.shared.removeSession(for: otherId)
            DatabaseManager.shared.currentSessionId = nil
        }

        DatabaseManager.shared.finalizeConnectionFailure(for: failedId, cancelled: false)

        #expect(DatabaseManager.shared.currentSessionId == otherId)
        #expect(DatabaseManager.shared.activeSessions[otherId] != nil)
    }
}
