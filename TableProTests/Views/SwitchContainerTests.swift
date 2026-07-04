//
//  SwitchContainerTests.swift
//  TableProTests
//
//  Regression coverage for #1807: Oracle declares schema-only switching, so
//  the container switcher must route through switchSchema.
//

import Foundation
import Testing

@testable import TablePro

@Suite("SwitchContainer")
@MainActor
struct SwitchContainerTests {
    @Test("switchContainer routes Oracle to a schema switch")
    func oracleRoutesToSchemaSwitch() async {
        let connection = TestFixtures.makeConnection(type: .oracle)
        let driver = MockDatabaseDriver(connection: connection)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: driver),
            for: connection.id
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        await coordinator.switchContainer(to: "HR")

        #expect(driver.switchSchemaCallCount == 1)
        #expect(driver.currentSchema == "HR")
        #expect(coordinator.toolbarState.currentSchema == "HR")
        #expect(DatabaseManager.shared.session(for: connection.id)?.currentSchema == "HR")
    }
}
