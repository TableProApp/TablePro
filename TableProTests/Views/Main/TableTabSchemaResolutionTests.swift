//
//  TableTabSchemaResolutionTests.swift
//  TableProTests
//
//  Tests for the first-load schema backstop: a table tab created without a
//  schema identity (Quick Switcher, MCP tool, restored tabs) is stamped with
//  the session's current schema before its query runs. Regression coverage
//  for #1774.
//

import Foundation
import Testing

@testable import TablePro

@Suite("TableTabSchemaResolution")
struct TableTabSchemaResolutionTests {
    @MainActor
    private func makeCoordinator(
        connection: DatabaseConnection,
        tabManager: QueryTabManager
    ) -> MainContentCoordinator {
        MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    @Test("Stamps the session's current schema and rebuilds the query")
    @MainActor
    func stampsSchemaAndRebuildsQuery() throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        var session = ConnectionSession(connection: connection)
        session.currentSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = makeCoordinator(connection: connection, tabManager: tabManager)
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "routes",
            databaseType: connection.type,
            databaseName: "testdb"
        )
        #expect(tabManager.selectedTab?.tableContext.schemaName == nil)
        let tabId = try #require(tabManager.selectedTab?.id)

        let resolved = coordinator.resolveTableTabSchemaIfNeeded(tabId: tabId)

        #expect(resolved == true)
        #expect(tabManager.selectedTab?.tableContext.schemaName == "sales")
        #expect(tabManager.selectedTab?.content.query.contains("sales") == true)
    }

    @Test("Leaves an already-resolved schema untouched")
    @MainActor
    func leavesResolvedSchemaUntouched() throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        var session = ConnectionSession(connection: connection)
        session.currentSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = makeCoordinator(connection: connection, tabManager: tabManager)
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "routes",
            databaseType: connection.type,
            databaseName: "testdb",
            schemaName: "audit"
        )
        let tabId = try #require(tabManager.selectedTab?.id)

        let resolved = coordinator.resolveTableTabSchemaIfNeeded(tabId: tabId)

        #expect(resolved == false)
        #expect(tabManager.selectedTab?.tableContext.schemaName == "audit")
    }

    @Test("No-op without a session")
    @MainActor
    func noOpWithoutSession() throws {
        let connection = TestFixtures.makeConnection()
        let tabManager = QueryTabManager()
        let coordinator = makeCoordinator(connection: connection, tabManager: tabManager)
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "routes",
            databaseType: connection.type,
            databaseName: "testdb"
        )
        let tabId = try #require(tabManager.selectedTab?.id)

        let resolved = coordinator.resolveTableTabSchemaIfNeeded(tabId: tabId)

        #expect(resolved == false)
        #expect(tabManager.selectedTab?.tableContext.schemaName == nil)
    }

    @Test("No-op for a query tab")
    @MainActor
    func noOpForQueryTab() throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        var session = ConnectionSession(connection: connection)
        session.currentSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = makeCoordinator(connection: connection, tabManager: tabManager)
        defer { coordinator.teardown() }

        tabManager.addTab(databaseName: "testdb")
        let tabId = try #require(tabManager.selectedTab?.id)

        let resolved = coordinator.resolveTableTabSchemaIfNeeded(tabId: tabId)

        #expect(resolved == false)
    }
}
