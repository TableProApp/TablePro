//
//  ServerDashboardSessionRouteTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct ServerDashboardSessionRouteTests {
    private struct Fixture {
        let connection: DatabaseConnection
        let driver: MockDatabaseDriver
        let viewModel: ServerDashboardViewModel
    }

    // No database chosen, so the metadata route is the session itself.
    private func makeServerScopedFixture() -> Fixture {
        let connection = TestFixtures.makeConnection(database: "", type: .mysql)
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let viewModel = ServerDashboardViewModel(connectionId: connection.id, databaseType: .mysql, services: .live)
        return Fixture(connection: connection, driver: driver, viewModel: viewModel)
    }

    @Test("A refresh read on the session leaves an open transaction's confirmation current")
    func refreshKeepsTheTurnRevision() async throws {
        let fixture = makeServerScopedFixture()
        defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
        let manager = DatabaseManager.shared
        let scope = try #require(manager.browseScope(for: fixture.connection.id))
        #expect(manager.metadataRoute(for: scope) == .sessionDriver)
        let before = manager.sessionTransactions.turnRevision(for: fixture.connection.id)

        await fixture.viewModel.refreshNow()

        #expect(!fixture.driver.executedQueries.isEmpty)
        #expect(manager.sessionTransactions.turnRevision(for: fixture.connection.id) == before)
    }

    @Test("Cancel on a session-routed connection runs while a tab's statement holds the session's turn")
    func cancelDoesNotWaitForTheSessionTurn() async throws {
        let fixture = makeServerScopedFixture()
        defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
        let manager = DatabaseManager.shared

        let acquired = AsyncGate()
        let release = AsyncGate()
        let tab = Task { @MainActor in
            try await manager.sessionDriverGate.withExclusiveAccess(manager.browsedGateKey(for: fixture.connection.id)) {
                await acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        fixture.viewModel.confirmCancelQuery(DashboardSession(
            id: "42", user: "app", database: "", state: "executing", durationSeconds: 3, duration: "3s",
            query: "SELECT SLEEP(3)"
        ))
        let cancel = Task { await fixture.viewModel.executeCancelQuery() }
        try await waitUntil { fixture.driver.executedQueries.contains("KILL QUERY 42") }

        await release.open()
        try await tab.value
        await cancel.value
        #expect(fixture.viewModel.actionError == nil)
    }
}
