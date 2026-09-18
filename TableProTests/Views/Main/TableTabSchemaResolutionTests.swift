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
        session.browseSchema = "sales"
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
        session.browseSchema = "sales"
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
        session.browseSchema = "sales"
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

    /// A schema belongs to the database that holds it, so the first load stamping the browsed one
    /// onto a tab bound elsewhere made its query name a relation that database may not have.
    @Test("Leaves a tab bound to another database without a schema")
    @MainActor
    func leavesForeignDatabaseTabUnqualified() throws {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        var session = ConnectionSession(connection: connection)
        session.status = .connected
        session.browseSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = makeCoordinator(connection: connection, tabManager: tabManager)
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "events", databaseType: connection.type, databaseName: "analytics")
        let tabId = try #require(tabManager.selectedTab?.id)

        #expect(coordinator.resolveTableTabSchemaIfNeeded(tabId: tabId) == false)
        #expect(tabManager.selectedTab?.tableContext.schemaName == nil)
    }

    @Test("Stamps a tab that follows the browsed database")
    @MainActor
    func stampsTabFollowingBrowsedDatabase() throws {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        var session = ConnectionSession(connection: connection)
        session.status = .connected
        session.browseSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = makeCoordinator(connection: connection, tabManager: tabManager)
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "events", databaseType: connection.type, databaseName: "")
        let tabId = try #require(tabManager.selectedTab?.id)

        #expect(coordinator.resolveTableTabSchemaIfNeeded(tabId: tabId) == true)
        #expect(tabManager.selectedTab?.tableContext.schemaName == "sales")
    }

    /// A table opened from a link before the connection is up is recorded in Recent while the
    /// session has no schema yet. Left that way, clicking the entry later opened the same name in
    /// whichever schema was browsed by then, and opening the table again listed it twice.
    @Test("A Recent entry recorded before connecting takes the schema the tab resolves")
    @MainActor
    func recentEntryTakesResolvedSchema() throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let store = RecentTablesStore.shared
        defer {
            store.removeEntries(for: connection.id)
            SharedSidebarState.removeConnection(connection.id)
        }
        store.record(
            connectionId: connection.id, database: "testdb", schema: nil, name: "routes",
            isView: false, objectType: nil
        )

        let state = SessionStateFactory.create(
            connection: connection,
            payload: EditorTabPayload(connectionId: connection.id, tabType: .table, tableName: "routes")
        )
        let tabId = try #require(state.tabManager.selectedTab?.id)

        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        session.browseSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(state.coordinator.resolveTableTabSchemaIfNeeded(tabId: tabId))
        #expect(store.entries(connectionId: connection.id).map(\.schema) == ["sales"])
        state.coordinator.teardown()

        DatabaseManager.shared.updateSession(connection.id) { $0.browseSchema = "audit" }
        let entry = try #require(store.entries(connectionId: connection.id).first)
        let tabManager = QueryTabManager()
        let coordinator = makeCoordinator(connection: connection, tabManager: tabManager)
        defer { coordinator.teardown() }

        coordinator.openTableTab(entry.tableInfo, schema: entry.schema)

        #expect(tabManager.selectedTab?.tableContext.schemaName == "sales")
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
        session.status = .connected
        session.browseSchema = sessionSchema
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

    @Test("A table opened in another database takes no schema from the browsed one")
    func foreignDatabaseTakesNoBrowsedSchema() {
        withCoordinator(sessionSchema: "custom") { coordinator, tabManager in
            coordinator.openTableTab("def_encounter", database: "Warehouse")
            let tab = tabManager.tabs.first
            #expect(tab?.tableContext.databaseName == "Warehouse")
            #expect(tab?.tableContext.schemaName == nil)
            #expect(tab?.content.query.contains("[custom]") == false)
        }
    }
}
