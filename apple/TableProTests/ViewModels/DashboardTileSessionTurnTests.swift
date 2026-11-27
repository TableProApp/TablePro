//
//  DashboardTileSessionTurnTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct DashboardTileSessionTurnTests {
    private static let saved = SQLFavorite(name: "Queued jobs", query: "SELECT count(*) FROM jobs")

    private struct Fixture {
        let connection: DatabaseConnection
        let driver: MockDatabaseDriver
        let viewModel: ServerDashboardViewModel
        let suite: EphemeralDefaults
    }

    // The tile layout is stored before the dashboard opens, so nothing runs until the test asks.
    private func makeFixture(checked schema: String) throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "app", type: .mysql)
        let driver = MockDatabaseDriver(connection: connection)
        driver.currentSchema = schema
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = "app"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let suite = try EphemeralDefaults()
        let defaults = suite.defaults
        let storage = ServerDashboardTileStorage(defaults: { defaults })
        storage.save(ServerDashboardTileLayout(tiles: [DashboardTile(favoriteId: Self.saved.id)]), for: connection.id)
        let checked = DatabaseScope(connectionId: connection.id, database: "app", schema: schema)
        let viewModel = ServerDashboardViewModel(
            connectionId: connection.id,
            databaseType: .mysql,
            services: .live,
            tileEnvironment: DashboardTileBoard.Environment(
                loadCatalog: { _ in DashboardSavedQueryCatalog(favorites: [Self.saved], folders: []) },
                savedQueriesDidChange: Empty<UUID?, Never>().eraseToAnyPublisher(),
                gate: AlwaysAllowGate(),
                forcesWrite: { _ in false },
                safeModeLevel: { _ in .silent },
                chartsAvailable: { false },
                nullDisplay: { "NULL" },
                storage: storage,
                runsIn: { _ in checked }
            )
        )
        return Fixture(connection: connection, driver: driver, viewModel: viewModel, suite: suite)
    }

    // A tab moves the shared driver to its own schema in its turn and leaves it there.
    @Test("A tile waits for the session's turn and runs in the schema the gate was asked about")
    func tileRunsInItsTurnPinnedToTheCheckedSchema() async throws {
        let fixture = try makeFixture(checked: "hr")
        defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
        let driver = fixture.driver

        let acquired = AsyncGate()
        let release = AsyncGate()
        let tab = Task { @MainActor in
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(
                DatabaseManager.shared.browsedGateKey(for: fixture.connection.id)
            ) {
                driver.currentSchema = "sales"
                await acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let refresh = Task { await fixture.viewModel.tileBoard.refresh(force: true) }
        try await waitUntil { DatabaseManager.shared.sessionDriverGate.waiterCount(for: fixture.connection.id) >= 1 }
        #expect(driver.executedQueries.isEmpty)

        await release.open()
        try await tab.value
        await refresh.value

        #expect(driver.executedQueries.contains(Self.saved.query))
        #expect(driver.currentSchema == "hr")
    }

    @Test("Cancelling a tile's run cancels its statement on the server")
    func cancelledTileStopsOnTheServer() async throws {
        let fixture = try makeFixture(checked: "hr")
        defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
        let driver = fixture.driver
        let held = AsyncGate()
        driver.executeGate = held

        let refresh = Task { await fixture.viewModel.tileBoard.refresh(force: true) }
        try await waitUntil { driver.executedQueries.contains(Self.saved.query) }
        refresh.cancel()
        try await waitUntil { driver.cancelQueryCallCount >= 1 }

        await held.open()
        await refresh.value
    }
}
