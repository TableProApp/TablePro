//
//  TableLoadForeignKeyPrefetchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct TableLoadForeignKeyPrefetchTests {
    /// The store refuses a second load for a scope already loading or loaded, so a nil answer while
    /// the rows are still on the wire means the table load started the schema's read itself.
    @Test("A table load starts its schema's foreign-key read before its rows arrive")
    func tableLoadStartsTheForeignKeyReadWithItsRows() async throws {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.bulkForeignKeyFetch = true
        driver.pausesNextUserQuery = true
        let paused = PauseFlag()
        driver.onUserQueryPaused = { paused.raise() }
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer {
            driver.resumeUserQuery()
            coordinator.cancelAllQueryTasks()
            coordinator.teardown()
            SchemaForeignKeyStore.shared.invalidate(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        let tab = QueryTab(title: "orders", query: "SELECT * FROM orders", tabType: .table, tableName: "orders")
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        let scope = try #require(coordinator.scope(for: tab))

        coordinator.executeQueryInternal("SELECT * FROM orders")
        for _ in 0 ..< 500 where !paused.isRaised {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(paused.isRaised, "The row query never reached the driver")

        #expect(SchemaForeignKeyStore.shared.prefetch(scope: scope) { nil } == nil)
    }
}

private final class PauseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.withLock { raised }
    }

    func raise() {
        lock.withLock { raised = true }
    }
}
