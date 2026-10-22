//
//  PluginBrowsedQueryTabEditabilityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class BrowseBuildingDriver: PluginDriverStub, @unchecked Sendable {
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

    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
}

private final class ShellDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func ping() async throws {}
}

/// A query tab keeps the table name of whatever result it last showed, and an older build filled it from the
/// query's text. On an engine whose plugin writes its own browse, or whose language is not SQL, the app no longer reads
/// that text, so a name left on the tab could point the grid's edits at a different table from the one the rows came
/// from.
@MainActor
struct PluginBrowsedQueryTabEditabilityTests {
    private func withCoordinator(
        type: DatabaseType,
        driver: any PluginDatabaseDriver = BrowseBuildingDriver(),
        selecting tab: QueryTab,
        alongside others: [QueryTab] = [],
        _ body: (MainContentCoordinator) -> Void
    ) {
        let connection = TestFixtures.makeConnection(type: type)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
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

    @Test("A MongoDB query tab carrying a stale collection name stays read-only, whatever its statement", arguments: [
        "db.orders.aggregate([{$group: {_id: \"$customerId\", n: {$sum: 1}}}])",
        "db.getCollection(\"orders\").find({}, {renamed: \"$a\"})",
        "db.customers.find()"
    ])
    func staleMongoQueryTabNameIsNotTrusted(statement: String) {
        for driver: any PluginDatabaseDriver in [BrowseBuildingDriver(), ShellDriver()] {
            var tab = QueryTab(query: statement, tabType: .query)
            tab.tableContext.tableName = "orders"
            withCoordinator(type: .mongodb, driver: driver, selecting: tab) { coordinator in
                let resolved = coordinator.resolveTableEditability(tab: tab, sql: tab.content.query)

                #expect(resolved.tableName == nil)
                #expect(!resolved.isEditable)
            }
        }
    }

    @Test("A MongoDB table tab stays editable on its own collection")
    func mongoTableTabKeepsItsCollection() {
        var tab = QueryTab(query: "", tabType: .table)
        tab.tableContext.tableName = "orders"
        withCoordinator(type: .mongodb, driver: ShellDriver(), selecting: tab) { coordinator in
            let resolved = coordinator.resolveTableEditability(tab: tab, sql: "")

            #expect(resolved.tableName == "orders")
            #expect(resolved.isEditable)
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
