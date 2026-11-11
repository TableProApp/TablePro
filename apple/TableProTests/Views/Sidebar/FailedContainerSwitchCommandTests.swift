//
//  FailedContainerSwitchCommandTests.swift
//  TableProTests
//
//  A command on a row in another database must not run where the session still is after a failed switch.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class CancelledSwitchDriverStub: PluginDriverStub, @unchecked Sendable {
    func switchDatabase(to database: String) async throws {
        throw CancellationError()
    }
}

@MainActor
struct FailedContainerSwitchCommandTests {
    private func withCoordinator(
        driver stub: any PluginDatabaseDriver,
        _ body: (MainContentCoordinator, DatabaseConnection) async throws -> Void
    ) async throws {
        let connection = TestFixtures.makeConnection(database: "db_a", type: .mysql)
        let driver = PluginDriverAdapter(connection: connection, pluginDriver: stub)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: QueryTabManager(containerTarget: .database, visibleContainer: "db_a"),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try await body(coordinator, connection)
    }

    @Test("A cancelled database switch reports that the window did not get there")
    func cancelledSwitchReportsFailure() async throws {
        try await withCoordinator(driver: CancelledSwitchDriverStub()) { coordinator, connection in
            let landed = await coordinator.switchContainers(database: "db_b", schema: nil)

            #expect(!landed)
            #expect(DatabaseManager.shared.session(for: connection.id)?.resolvedBrowseDatabase == "db_a")
        }
    }

    @Test("A switch that lands, or was never needed, reports success")
    func landedSwitchReportsSuccess() async throws {
        try await withCoordinator(driver: SwitchingDriverStub()) { coordinator, _ in
            let alreadyThere = await coordinator.switchContainers(database: "db_a", schema: nil)
            let moved = await coordinator.switchContainers(database: "db_b", schema: nil)

            #expect(alreadyThere)
            #expect(moved)
        }
    }

    @Test("A sidebar row's activation fails with the switch, so its command does not run")
    func rowActivationFailsWithTheSwitch() async throws {
        try await withCoordinator(driver: CancelledSwitchDriverStub()) { coordinator, _ in
            let outline = DatabaseTreeOutlineCoordinator()
            outline.mainCoordinator = coordinator
            let ref = DatabaseTreeTableRef(database: "db_b", schema: nil, table: TestFixtures.makeTableInfo(name: "orders"))

            let activated = await outline.activate(ref)

            #expect(!activated)
        }
    }
}
