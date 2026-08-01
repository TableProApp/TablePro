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

/// A table tab must carry the schema the row was listed under. SQL Server has no
/// session-level schema, so a tab that opens without one queries an unqualified
/// name and the server answers "Invalid object name" (#2004).
@Suite("TableTabListingSchema")
@MainActor
struct TableTabListingSchemaTests {
    private func withCoordinator(
        sessionSchema: String?,
        _ body: (MainContentCoordinator, QueryTabManager) -> Void
    ) {
        let connection = TestFixtures.makeConnection(database: "AppDb", type: .mssql)
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.currentSchema = sessionSchema
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        body(coordinator, tabManager)
    }

    private func makeTable(schema: String?) -> TableInfo {
        TableInfo(name: "def_encounter", type: .table, rowCount: nil, schema: schema)
    }

    @Test("An explicit schema wins over the listed table's own schema")
    func explicitSchemaWins() {
        withCoordinator(sessionSchema: "dbo") { coordinator, tabManager in
            coordinator.openTableTab(makeTable(schema: "stale"), schema: "custom")
            #expect(tabManager.tabs.first?.tableContext.schemaName == "custom")
        }
    }

    @Test("The listed table's schema is used when the caller gives none")
    func tableSchemaIsUsed() {
        withCoordinator(sessionSchema: "dbo") { coordinator, tabManager in
            coordinator.openTableTab(makeTable(schema: "custom"))
            #expect(tabManager.tabs.first?.tableContext.schemaName == "custom")
        }
    }

    @Test("The session schema is the last resort, not the first")
    func sessionSchemaIsLastResort() {
        withCoordinator(sessionSchema: "custom") { coordinator, tabManager in
            coordinator.openTableTab(makeTable(schema: nil))
            #expect(tabManager.tabs.first?.tableContext.schemaName == "custom")
        }
    }

    @Test("A blank schema on the listed table does not reach the tab")
    func blankTableSchemaFallsBack() {
        withCoordinator(sessionSchema: "custom") { coordinator, tabManager in
            coordinator.openTableTab(makeTable(schema: ""))
            #expect(tabManager.tabs.first?.tableContext.schemaName == "custom")
        }
    }

    @Test("A blank session schema leaves the tab without one instead of an empty qualifier")
    func blankSessionSchemaStaysAbsent() {
        withCoordinator(sessionSchema: "") { coordinator, tabManager in
            coordinator.openTableTab(makeTable(schema: nil))
            #expect(tabManager.tabs.first?.tableContext.schemaName == nil)
        }
    }

    @Test("A table outside the default schema opens a schema-qualified query")
    func queryIsSchemaQualified() {
        withCoordinator(sessionSchema: "dbo") { coordinator, tabManager in
            coordinator.openTableTab(makeTable(schema: "custom"))
            let query = tabManager.tabs.first?.content.query ?? ""
            #expect(query.contains("[custom].[def_encounter]"))
        }
    }
}
