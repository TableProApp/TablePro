//
//  CredentialLeaseRoutingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Credential lease routing", .serialized)
@MainActor
struct CredentialLeaseRoutingTests {
    private func ending(_ connectionId: UUID, _ driver: DatabaseDriver) -> CredentialLeaseEnding {
        CredentialLeaseEnding(connectionId: connectionId, driver: ObjectIdentifier(driver), remaining: .seconds(60))
    }

    @Test("The session's own driver reconnects; a parked lane closes; anything else is left alone")
    func routesByDriver() {
        let connection = TestFixtures.makeConnection(database: "app")
        let home = MockDatabaseDriver(connection: connection)
        let lane = MockDatabaseDriver(connection: connection)
        let stranger = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection)
        session.driver = home
        session.status = .connected
        let manager = DatabaseManager.shared
        manager.injectSession(session, for: connection.id)
        manager.sessionLanes.park(lane, database: "logs", for: connection.id)
        defer {
            manager.sessionLanes.closeAll(for: connection.id)
            manager.removeSession(for: connection.id)
        }

        #expect(manager.credentialLeaseAction(for: ending(connection.id, home)) == .reconnectSession)
        #expect(manager.credentialLeaseAction(for: ending(connection.id, lane)) == .closeLane(database: "logs"))
        #expect(manager.credentialLeaseAction(for: ending(connection.id, stranger)) == .none)
        #expect(manager.credentialLeaseAction(for: ending(UUID(), home)) == .none)
    }

    @Test("A lane whose lease is ending is closed, so its next use opens one with a new lease")
    func closesEndingLane() async {
        let connection = TestFixtures.makeConnection(database: "app")
        let home = MockDatabaseDriver(connection: connection)
        let lane = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection)
        session.driver = home
        session.status = .connected
        let manager = DatabaseManager.shared
        manager.injectSession(session, for: connection.id)
        manager.sessionLanes.park(lane, database: "logs", for: connection.id)
        defer {
            manager.sessionLanes.closeAll(for: connection.id)
            manager.removeSession(for: connection.id)
        }

        await manager.credentialLeaseEnding(ending(connection.id, lane))

        #expect(manager.sessionLanes.parkedDriver(for: connection.id, database: "logs") == nil)
        #expect(lane.disconnectCallCount == 1)
        #expect(manager.activeSessions[connection.id]?.driver === home)
    }

    @Test("A browsed driver replaced while it held a transaction reports the loss to the next statement, once")
    func reportsLostBrowsedTransaction() async throws {
        let connection = TestFixtures.makeConnection(database: "app", type: .mysql)
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.browseDatabase = "app"
        session.status = .connected
        let manager = DatabaseManager.shared
        manager.injectSession(session, for: connection.id)
        defer { manager.removeSession(for: connection.id) }
        manager.sessionLanes.markTransactionLost(database: "app", for: connection.id)
        let scope = DatabaseScope(connectionId: connection.id, database: "app", schema: nil)

        let error = await #expect(throws: DatabaseError.self) {
            try await manager.withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .protectedWrite) { _ in }
        }
        #expect(error?.localizedDescription.contains(DatabaseManager.parkedTransactionLostMessage(database: "app")) == true)
        try await manager.withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .protectedWrite) { _ in }
    }
}
