//
//  MetadataReadLendingTests.swift
//  TableProTests
//
//  Right after connect the pool holds nothing, so the first table list waited for a whole new
//  connection while the session that had just logged in sat idle (#4542).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct MetadataReadLendingTests {
    private func makeSession(commitMode: ConnectionCommitMode = .automatic) -> (DatabaseConnection, MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        let driver = MockDatabaseDriver(connection: connection)
        driver.currentSchema = "public"
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = "app"
        session.browseSchema = "public"
        session.commitMode = commitMode
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func cleanUp(_ connectionId: UUID) {
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
        DatabaseManager.shared.removeSession(for: connectionId)
    }

    private func scope(_ connection: DatabaseConnection, database: String = "app", schema: String? = "public") -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: database, schema: schema)
    }

    @Test("An idle session serves a catalog read when the pool holds no connection for it")
    func idleSessionServesTheFirstRead() async throws {
        let (connection, driver) = makeSession()
        defer { cleanUp(connection.id) }
        let place = scope(connection)
        #expect(DatabaseManager.shared.metadataRoute(for: place) == .pooled)

        let served = try await DatabaseManager.shared.withMetadataRead(scope: place) { ObjectIdentifier($0) }

        #expect(served == ObjectIdentifier(driver))
        #expect(driver.switchSchemaCallCount == 0)
        #expect(DatabaseManager.shared.lentMetadataReads.isEmpty)
    }

    @Test("A session is not lent to a bulk read, or to a read on another database or schema")
    func lendsOnlyWhereTheSessionAlreadyIs() {
        let (connection, _) = makeSession()
        defer { cleanUp(connection.id) }
        let manager = DatabaseManager.shared

        #expect(manager.lendsSessionDriver(toMetadataReadOn: scope(connection), workload: .interactive))
        #expect(!manager.lendsSessionDriver(toMetadataReadOn: scope(connection), workload: .bulk))
        #expect(!manager.lendsSessionDriver(toMetadataReadOn: scope(connection, schema: "sales"), workload: .interactive))
        #expect(!manager.lendsSessionDriver(toMetadataReadOn: scope(connection, database: "billing"), workload: .interactive))
    }

    @Test("A pooled connection ready for the read keeps it off the session")
    func idlePooledConnectionKeepsTheReadOffTheSession() async throws {
        let (connection, driver) = makeSession()
        defer { cleanUp(connection.id) }
        let pooled = MockDatabaseDriver(connection: connection)
        pooled.currentSchema = "public"
        MetadataConnectionPool.shared.injectEntry(pooled, scope: scope(connection))

        #expect(!DatabaseManager.shared.lendsSessionDriver(toMetadataReadOn: scope(connection), workload: .interactive))
        let served = try await DatabaseManager.shared.withMetadataRead(scope: scope(connection)) { ObjectIdentifier($0) }
        #expect(served == ObjectIdentifier(pooled))
        #expect(served != ObjectIdentifier(driver))
    }

    @Test("A session holding a turn, or in manual commit, is not lent")
    func busyOrManualCommitSessionIsNotLent() async throws {
        let (connection, _) = makeSession()
        defer { cleanUp(connection.id) }
        let manager = DatabaseManager.shared
        let release = AsyncGate()
        let acquired = AsyncGate()
        let holder = Task { @MainActor in
            try await manager.sessionDriverGate.withExclusiveAccess(manager.browsedGateKey(for: connection.id)) {
                await acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()
        #expect(!manager.lendsSessionDriver(toMetadataReadOn: scope(connection), workload: .interactive))
        await release.open()
        try await holder.value
        #expect(manager.lendsSessionDriver(toMetadataReadOn: scope(connection), workload: .interactive))

        let (manual, _) = makeSession(commitMode: .manual)
        defer { cleanUp(manual.id) }
        #expect(!manager.lendsSessionDriver(toMetadataReadOn: scope(manual), workload: .interactive))
    }

    @Test("A session whose transaction state is unknown or open is not lent, and one read as idle is")
    func sessionOutsideAKnownIdleStateIsNotLent() throws {
        let (connection, driver) = makeSession()
        defer { cleanUp(connection.id) }
        let manager = DatabaseManager.shared
        let key = try #require(manager.sessionKey(for: scope(connection)))

        manager.sessionTransactions.record(.unknown, on: driver, for: key)
        #expect(!manager.lendsSessionDriver(toMetadataReadOn: scope(connection), workload: .interactive))

        manager.sessionTransactions.record(.inTransaction, on: driver, for: key)
        #expect(!manager.lendsSessionDriver(toMetadataReadOn: scope(connection), workload: .interactive))

        manager.sessionTransactions.record(.idle, on: driver, for: key)
        #expect(manager.lendsSessionDriver(toMetadataReadOn: scope(connection), workload: .interactive))
    }
}
