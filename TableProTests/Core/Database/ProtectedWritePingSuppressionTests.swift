//
//  ProtectedWritePingSuppressionTests.swift
//  TableProTests
//
//  The health check skips a connection with a query on it, but only for max(queryTimeout, 300)
//  seconds. An import or a dump runs legitimately past that, and a check that goes ahead there can
//  fail, reconnect, and disconnect the handle out from under a batch halfway through applying it.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Protected write ping suppression", .serialized)
@MainActor
struct ProtectedWritePingSuppressionTests {
    private func seed(_ policy: DriverCancellationPolicy, for connectionId: UUID) {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        DatabaseManager.shared.runningDrivers[connectionId] = [
            UUID(): RunningDriver(driver: MockDatabaseDriver(connection: connection), policy: policy)
        ]
    }

    @Test("a write in flight is reported, whatever its age")
    func protectedWriteIsReported() {
        let connectionId = UUID()
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connectionId) }

        seed(.protectedWrite, for: connectionId)

        #expect(DatabaseManager.shared.holdsProtectedWrite(connectionId))
    }

    /// The override was written for a read that hung, where pinging past it costs nothing. That
    /// case has to keep working, or a genuinely stuck connection is never noticed.
    @Test("a read that hung is still not treated as a protected write")
    func cancellableReadIsNotProtected() {
        let connectionId = UUID()
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connectionId) }

        seed(.cancellableRead, for: connectionId)

        #expect(!DatabaseManager.shared.holdsProtectedWrite(connectionId))
    }

    @Test("a connection running nothing holds no write")
    func idleConnectionHoldsNothing() {
        #expect(!DatabaseManager.shared.holdsProtectedWrite(UUID()))
    }

    @Test("a write alongside a read still counts as a write")
    func aWriteBesideAReadStillCounts() {
        let connectionId = UUID()
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connectionId) }
        let connection = TestFixtures.makeConnection(type: .postgresql)

        DatabaseManager.shared.runningDrivers[connectionId] = [
            UUID(): RunningDriver(driver: MockDatabaseDriver(connection: connection), policy: .cancellableRead),
            UUID(): RunningDriver(driver: MockDatabaseDriver(connection: connection), policy: .protectedWrite),
        ]

        #expect(DatabaseManager.shared.holdsProtectedWrite(connectionId))
    }
}
