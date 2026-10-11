//
//  QuickSwitcherItemIdentityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// Three places produce the key a table is remembered under: the tab open chokepoint, which only
/// learns a Bool for the kind, the All and Tables scopes, and the Connections scope. They have to
/// agree or the Recent section and the frecency boost silently skip the object.
struct QuickSwitcherItemIdentityTests {
    private let connectionId = UUID()

    private func recordedByTabOpen(
        _ table: TableInfo,
        database: String,
        switchesDatabases: Bool = true
    ) -> String {
        SharedSidebarState.tableFrecencyKey(
            database: database,
            schema: table.schema,
            name: table.name,
            connectionSwitchesDatabases: switchesDatabases
        )
    }

    private func listedInTablesScope(
        _ table: TableInfo,
        database: String,
        switchesDatabases: Bool = true
    ) -> String? {
        QuickSwitcherViewModel.makeTableItems(
            [table],
            database: database,
            connectionSwitchesDatabases: switchesDatabases,
            browseSchema: "public",
            openTables: []
        ).first?.frecencyKey
    }

    private func listedInConnectionsScope(
        _ table: TableInfo,
        database: String,
        switchesDatabases: Bool = true
    ) -> String? {
        let target = QuickSwitcherTarget(
            connectionId: connectionId,
            connectionName: "Primary",
            databaseName: database,
            schemaName: "public"
        )
        return QuickSwitcherViewModel.makeCrossConnectionItems(
            tables: [table],
            target: target,
            connectionSwitchesDatabases: switchesDatabases
        ).first?.frecencyKey
    }

    private func key(_ name: String, schema: String?, database: String?, switchesDatabases: Bool = true) -> String {
        QuickSwitcherFrecencyKey.table(
            name: name,
            schema: schema,
            in: .init(database: database, connectionSwitchesDatabases: switchesDatabases)
        )
    }

    @Test("Every table type records and lists under the same key in every scope", arguments: [
        TableInfo.TableType.table,
        .view,
        .materializedView,
        .foreignTable,
        .systemTable,
        .partitionedTable,
        .externalTable,
        .sequence
    ])
    func everyTypeAgrees(type: TableInfo.TableType) {
        let table = TableInfo(name: "sales", type: type, rowCount: nil, schema: "public")
        let recorded = recordedByTabOpen(table, database: "app")

        #expect(listedInTablesScope(table, database: "app") == recorded)
        #expect(listedInConnectionsScope(table, database: "app") == recorded)
    }

    @Test("A table listed without a schema is keyed under the schema its tab resolves to")
    func schemalessListingUsesTheResolvedSchema() {
        let table = TableInfo(name: "orders", type: .table, rowCount: nil, schema: nil)
        let recorded = SharedSidebarState.tableFrecencyKey(
            database: "app", schema: "public", name: "orders", connectionSwitchesDatabases: true
        )

        #expect(listedInTablesScope(table, database: "app") == recorded)
        #expect(listedInConnectionsScope(table, database: "app") == recorded)
    }

    @Test("One schema and name listed under two kinds is one row in every scope")
    func duplicateListingIsOneRow() {
        let tables = [
            TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public"),
            TableInfo(name: "orders", type: .view, rowCount: nil, schema: "public")
        ]
        let listed = QuickSwitcherViewModel.makeTableItems(
            tables, database: "app", connectionSwitchesDatabases: true, browseSchema: "public", openTables: []
        )
        let connected = QuickSwitcherViewModel.makeCrossConnectionItems(
            tables: tables,
            target: QuickSwitcherTarget(
                connectionId: connectionId, connectionName: "Primary", databaseName: "app", schemaName: "public"
            ),
            connectionSwitchesDatabases: true
        )

        #expect(listed.map(\.tableType) == [.table])
        #expect(connected.map(\.tableType) == [.table])
    }

    @Test("A connection that reaches one database records and lists under the same key")
    func singleDatabaseConnectionAgrees() {
        let table = TableInfo(name: "users", type: .table, rowCount: nil, schema: "main")
        let recorded = recordedByTabOpen(table, database: "/Users/me/app.sqlite", switchesDatabases: false)

        #expect(listedInTablesScope(table, database: "/Users/me/app.sqlite", switchesDatabases: false) == recorded)
        #expect(listedInConnectionsScope(table, database: "/Users/me/app.sqlite", switchesDatabases: false) == recorded)
    }

    @Test("The database qualifies the key on a connection that switches databases")
    func databaseQualifiesTheKey() {
        #expect(key("users", schema: "public", database: "app_prod") != key("users", schema: "public", database: "app_staging"))
    }

    @Test("A connection that reaches one database keeps the key it always had")
    func singleDatabaseKeyIsUnchanged() {
        #expect(key("users", schema: "public", database: "/Users/me/app.sqlite", switchesDatabases: false) == "table_public.users")
        #expect(key("users", schema: nil, database: "/Users/me/app.sqlite", switchesDatabases: false) == "table_users")
    }

    @Test("No database selected leaves the key unqualified")
    func emptyDatabaseIsUnqualified() {
        #expect(key("users", schema: "public", database: "") == key("users", schema: "public", database: nil))
    }

    @Test("A qualified key can never equal a key recorded before it had a database")
    func qualifiedKeysAreDisjointFromUnqualifiedOnes() {
        let qualified = key("c", schema: "b", database: "a")

        #expect(qualified != "table_a.b.c")
        #expect(qualified != key("c", schema: "a.b", database: nil))
        #expect(!qualified.hasPrefix("table_"))
    }

    @Test("A slash in a database name cannot move a component into another")
    func slashInDatabaseStaysInsideIt() {
        #expect(key("c", schema: nil, database: "a/b") != key("b/c", schema: nil, database: "a"))
    }

    @Test("A schema qualifies the key")
    func schemaQualifiesTheKey() {
        #expect(key("users", schema: "public", database: "app") != key("users", schema: "analytics", database: "app"))
    }

    @Test("A driver that reports no schema keeps a stable key")
    func noSchemaKeepsStableKey() {
        #expect(key("users", schema: nil, database: "app") == key("users", schema: "", database: "app"))
    }

    @Test("Different names never collide")
    func differentNamesDoNotCollide() {
        #expect(key("users", schema: "public", database: "app") != key("orders", schema: "public", database: "app"))
    }

    @Test("A statement keeps one key however many times it runs and however it is padded")
    func statementKeyIgnoresExecutionAndPadding() {
        #expect(QuickSwitcherFrecencyKey.queryHistory("SELECT 1") == QuickSwitcherFrecencyKey.queryHistory("  SELECT 1\n"))
        #expect(QuickSwitcherFrecencyKey.queryHistory("SELECT 1") != QuickSwitcherFrecencyKey.queryHistory("SELECT 2"))
        #expect(QuickSwitcherFrecencyKey.queryHistory("SELECT 1").hasPrefix("history_"))
    }

    @Test("A statement key has a fixed length whatever the statement's size")
    func statementKeyLengthIsFixed() {
        let short = QuickSwitcherFrecencyKey.queryHistory("SELECT 1")
        let long = QuickSwitcherFrecencyKey.queryHistory(String(repeating: "SELECT * FROM events; ", count: 10_000))

        #expect((short as NSString).length == (long as NSString).length)
    }
}
