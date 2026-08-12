//
//  HealthMonitorReconnectTests.swift
//  TableProTests
//
//  A background reconnect is not a teardown. It must leave the schema cache in place and
//  announce itself the way a first connect does, or the sidebar and the SQL editor's
//  autocomplete keep serving an empty schema with nothing scheduled to refill it.
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Health monitor reconnect", .serialized)
@MainActor
struct HealthMonitorReconnectTests {
    private func makeConnectedSession() -> DatabaseConnection {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.type = DatabaseType(rawValue: FakeMSSQLPlugin.databaseTypeId)
        var session = ConnectionSession(connection: connection)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private func cleanUp(_ connectionId: UUID) async {
        DatabaseManager.shared.removeSession(for: connectionId)
        await SchemaService.shared.invalidate(connectionId: connectionId)
    }

    @Test("a background reconnect keeps the loaded schema instead of clearing it")
    func reconnectKeepsTheLoadedSchema() async throws {
        let connection = makeConnectedSession()
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let scope = try #require(DatabaseManager.shared.driverScope(for: connection.id))
        await SchemaService.shared.load(
            scope: scope,
            driver: driver,
            connection: connection
        )
        #expect(SchemaService.shared.state(for: scope) == .loaded(driver.tablesToReturn))

        _ = await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: connection.id)

        #expect(SchemaService.shared.state(for: scope) == .loaded(driver.tablesToReturn))
        await cleanUp(connection.id)
    }

    @Test("a successful background reconnect announces itself so listeners reload")
    func successfulReconnectPostsDatabaseDidConnect() async {
        let connection = makeConnectedSession()
        var received: [UUID] = []
        let cancellable = AppEvents.shared.databaseDidConnect.sink { payload in
            received.append(payload.connectionId)
        }
        defer { cancellable.cancel() }

        let outcome = await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: connection.id)

        #expect(outcome == .success)
        #expect(received == [connection.id])
        await cleanUp(connection.id)
    }

    @Test("a reconnect for a session that is gone aborts without announcing anything")
    func missingSessionAborts() async {
        var received: [UUID] = []
        let cancellable = AppEvents.shared.databaseDidConnect.sink { payload in
            received.append(payload.connectionId)
        }
        defer { cancellable.cancel() }

        let outcome = await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: UUID())

        #expect(outcome == .abort)
        #expect(received.isEmpty)
    }
}
