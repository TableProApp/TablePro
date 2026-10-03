//
//  PluginBrowsedQueryTabEditabilityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class BrowseBuildingDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        "SELECT * FROM \(table)"
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

/// A query tab keeps the table name of whatever result it last showed, and an older build filled it from the
/// query's text. On a SQL engine whose plugin writes its own browse, the app no longer reads that text, so a name
/// left on the tab could point the grid's edits at a different table from the one the rows came from.
@Suite(.serialized)
@MainActor
struct PluginBrowsedQueryTabEditabilityTests {
    private func withCoordinator(
        type: DatabaseType,
        selecting tab: QueryTab,
        alongside others: [QueryTab] = [],
        _ body: (MainContentCoordinator) -> Void
    ) {
        let connection = TestFixtures.makeConnection(type: type)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: BrowseBuildingDriver())
        )
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        tabManager.tabs.append(contentsOf: others + [tab])
        tabManager.selectedTabId = tab.id
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }
        body(coordinator)
    }

    @Test("A Cassandra query tab carrying a stale table name stays read-only", arguments: [
        DatabaseType.cassandra, .scylladb
    ])
    func staleQueryTabNameIsNotTrusted(type: DatabaseType) {
        var tab = QueryTab(query: "SELECT * FROM new_table", tabType: .query)
        tab.tableContext.tableName = "old_table"
        withCoordinator(type: type, selecting: tab) { coordinator in
            let resolved = coordinator.resolveTableEditability(tab: tab, sql: tab.content.query)

            #expect(resolved.tableName == nil)
            #expect(!resolved.isEditable)
        }
    }

    @Test("A table tab that is not selected resolves its own table, not the selected tab's")
    func backgroundTableTabResolvesItsOwnTable() {
        var background = QueryTab(query: "", tabType: .table)
        background.tableContext.tableName = "events"
        var selected = QueryTab(query: "", tabType: .table)
        selected.tableContext.tableName = "users"
        withCoordinator(type: .cassandra, selecting: selected, alongside: [background]) { coordinator in
            let resolved = coordinator.resolveTableEditability(tab: background, sql: "")

            #expect(resolved.tableName == "events")
        }
    }

    @Test("A Cassandra table tab stays editable on its own table")
    func tableTabKeepsItsTable() {
        var tab = QueryTab(query: "", tabType: .table)
        tab.tableContext.tableName = "events"
        withCoordinator(type: .cassandra, selecting: tab) { coordinator in
            let resolved = coordinator.resolveTableEditability(tab: tab, sql: "")

            #expect(resolved.tableName == "events")
            #expect(resolved.isEditable)
        }
    }
}
