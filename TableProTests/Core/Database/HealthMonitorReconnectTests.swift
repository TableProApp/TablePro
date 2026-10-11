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

    private func makeSessionFailingToReconnect(
        with error: any Error & Sendable,
        after delay: Duration = .zero
    ) -> (connection: DatabaseConnection, driver: MockDatabaseDriver) {
        let connection = makeConnectedSession()
        let driver = MockDatabaseDriver()
        DatabaseManager.shared.updateSession(connection.id) { $0.driver = driver }
        FakeMSSQLPlugin.failConnect(for: connection.id, with: error, after: delay)
        return (connection, driver)
    }

    private func cleanUp(_ connectionId: UUID) async {
        FakeMSSQLPlugin.clearConnectFailure(for: connectionId)
        DatabaseManager.shared.removeSession(for: connectionId)
        await SchemaService.shared.invalidate(connectionId: connectionId)
    }

    @Test(
        "a TLS failure only a settings change can fix stops reconnecting and says why",
        arguments: TLSFailureFixtures.configurationFailures
    )
    func configurationTLSFailureStopsReconnecting(error: SSLHandshakeError) async {
        let (connection, driver) = makeSessionFailingToReconnect(with: error)
        let expected = ConnectionFailureClassifier.info(for: error)

        let outcome = await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: connection.id)

        let session = DatabaseManager.shared.activeSessions[connection.id]
        #expect(outcome == .abort)
        #expect(session?.liveness == .unreachable(expected))
        #expect(session?.status == .error(expected.message))
        #expect(session?.reportedStatus == .error(expected.message))
        #expect(DatabaseManager.shared.disconnectReason(for: connection.id) == .sessionLost(expected))
        #expect(session?.driver === driver)
        await cleanUp(connection.id)
    }

    @Test(
        "a certificate failure keeps reconnecting and hands back the certificate reason",
        arguments: TLSFailureFixtures.certificateFailures
    )
    func certificateFailureKeepsReconnecting(error: SSLHandshakeError) async {
        let (connection, _) = makeSessionFailingToReconnect(with: error)

        let outcome = await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: connection.id)

        let session = DatabaseManager.shared.activeSessions[connection.id]
        #expect(outcome == .retry(ConnectionFailureClassifier.info(for: error)))
        #expect(session?.liveness == .live)
        #expect(session?.status == .connected)
        await cleanUp(connection.id)
    }

    @Test(
        "a TLS failure a server restart also produces keeps reconnecting with no reason of its own",
        arguments: TLSFailureFixtures.transientFailures
    )
    func transientTLSFailureKeepsReconnecting(error: SSLHandshakeError) async {
        let (connection, _) = makeSessionFailingToReconnect(with: error)

        let outcome = await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: connection.id)

        let session = DatabaseManager.shared.activeSessions[connection.id]
        #expect(outcome == .retry(nil))
        #expect(session?.liveness == .live)
        #expect(session?.status == .connected)
        await cleanUp(connection.id)
    }

    @Test("a server that refuses the connection keeps the reconnect going")
    func refusedConnectionKeepsReconnecting() async {
        let refused = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNREFUSED),
            userInfo: [NSLocalizedDescriptionKey: "Connection refused"]
        )
        let (connection, _) = makeSessionFailingToReconnect(with: refused)

        let outcome = await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: connection.id)

        #expect(outcome == .retry(nil))
        #expect(DatabaseManager.shared.activeSessions[connection.id]?.liveness == .live)
        await cleanUp(connection.id)
    }

    @Test("a late TLS failure from a reconnect that lost its race leaves the winner alone")
    func lateConfigurationFailureLeavesTheWinnerAlone() async {
        let error = SSLHandshakeError.clientCertRequired(serverMessage: "certificate required")
        let (connection, _) = makeSessionFailingToReconnect(with: error, after: .milliseconds(300))
        let connectionId = connection.id

        let attempt = Task { @MainActor in
            await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: connectionId)
        }
        try? await Task.sleep(for: .milliseconds(50))
        let replacement = MockDatabaseDriver()
        DatabaseManager.shared.updateSession(connectionId) { $0.driver = replacement }
        let outcome = await attempt.value

        let session = DatabaseManager.shared.activeSessions[connectionId]
        #expect(outcome == .abort)
        #expect(session?.driver === replacement)
        #expect(session?.liveness == .live)
        #expect(session?.status == .connected)
        #expect(DatabaseManager.shared.disconnectReason(for: connectionId) == nil)
        await cleanUp(connectionId)
    }

    @Test("a background reconnect keeps the loaded schema instead of clearing it")
    func reconnectKeepsTheLoadedSchema() async {
        let connection = makeConnectedSession()
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        await SchemaService.shared.load(
            connectionId: connection.id,
            driver: driver,
            connection: connection
        )
        #expect(SchemaService.shared.state(for: connection.id) == .loaded(driver.tablesToReturn))

        _ = await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: connection.id)

        #expect(SchemaService.shared.state(for: connection.id) == .loaded(driver.tablesToReturn))
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
