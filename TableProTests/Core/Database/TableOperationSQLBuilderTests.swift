//
//  TableOperationSQLBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubDropDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

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

/// A driver that answers the foreign-key questions, which `StubDropDriver` leaves at the protocol
/// default of nil. The two together are what the builder's contract is: whatever the connected
/// driver says, and nothing at all when it says nothing.
private final class StubForeignKeyDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

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

    func foreignKeyDisableStatements() -> [String]? { ["SET FOREIGN_KEY_CHECKS=0"] }
    func foreignKeyEnableStatements() -> [String]? { ["SET FOREIGN_KEY_CHECKS=1"] }
}

@Suite("TableOperationSQLBuilder")
@MainActor
struct TableOperationSQLBuilderTests {
    private func makeForeignKeyBuilder() -> TableOperationSQLBuilder {
        let connection = DatabaseConnection(name: "Test", type: .mysql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: StubForeignKeyDriver())
        return TableOperationSQLBuilder(
            connectionId: connection.id,
            databaseType: .mysql,
            tableInfoProvider: { [:] },
            adapterProvider: { adapter }
        )
    }

    private func makeBuilder(tables: [TableInfo]) -> TableOperationSQLBuilder {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: StubDropDriver())
        return TableOperationSQLBuilder(
            connectionId: connection.id,
            databaseType: .postgresql,
            tableInfoProvider: { Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) }) },
            adapterProvider: { adapter }
        )
    }

    @Test("Materialized view drops with DROP MATERIALIZED VIEW")
    func dropsMaterializedView() {
        let builder = makeBuilder(tables: [
            TableInfo(name: "daily_sales", type: .materializedView, rowCount: nil, schema: "public")
        ])
        let stmts = builder.generate(truncates: [], deletes: ["daily_sales"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP MATERIALIZED VIEW \"public\".\"daily_sales\""])
    }

    @Test("View drops with DROP VIEW")
    func dropsView() {
        let builder = makeBuilder(tables: [TableInfo(name: "active_users", type: .view, rowCount: nil)])
        let stmts = builder.generate(truncates: [], deletes: ["active_users"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP VIEW \"active_users\""])
    }

    @Test("Foreign table drops with DROP FOREIGN TABLE")
    func dropsForeignTable() {
        let builder = makeBuilder(tables: [TableInfo(name: "remote_orders", type: .foreignTable, rowCount: nil)])
        let stmts = builder.generate(truncates: [], deletes: ["remote_orders"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP FOREIGN TABLE \"remote_orders\""])
    }

    @Test("External table drops with DROP TABLE")
    func dropsExternalTable() {
        let builder = makeBuilder(tables: [TableInfo(name: "customers", type: .externalTable, rowCount: nil)])
        let stmts = builder.generate(truncates: [], deletes: ["customers"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP TABLE \"customers\""])
    }

    @Test("Plain table drops with DROP TABLE")
    func dropsTable() {
        let builder = makeBuilder(tables: [TableInfo(name: "orders", type: .table, rowCount: nil)])
        let stmts = builder.generate(truncates: [], deletes: ["orders"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP TABLE \"orders\""])
    }

    @Test("System table drops with DROP TABLE")
    func dropsSystemTable() {
        let builder = makeBuilder(tables: [TableInfo(name: "pg_stats", type: .systemTable, rowCount: nil)])
        let stmts = builder.generate(truncates: [], deletes: ["pg_stats"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP TABLE \"pg_stats\""])
    }

    @Test("Unresolvable name falls back to DROP TABLE")
    func fallsBackWhenLookupMisses() {
        let builder = makeBuilder(tables: [])
        let stmts = builder.generate(truncates: [], deletes: ["ghost"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP TABLE \"ghost\""])
    }

    @Test("Cascade applies to materialized view drops")
    func cascadeAppliesToMaterializedView() {
        let builder = makeBuilder(tables: [TableInfo(name: "daily_sales", type: .materializedView, rowCount: nil)])
        let options = ["daily_sales": TableOperationOptions(cascade: true)]
        let stmts = builder.generate(truncates: [], deletes: ["daily_sales"], options: options, includeFKHandling: false)
        #expect(stmts == ["DROP MATERIALIZED VIEW \"daily_sales\" CASCADE"])
    }

    @Test("Drop qualifies schema when TableInfo carries one")
    func qualifiesSchema() {
        let builder = makeBuilder(tables: [TableInfo(name: "orders", type: .table, rowCount: nil, schema: "sales")])
        let stmts = builder.generate(truncates: [], deletes: ["orders"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP TABLE \"sales\".\"orders\""])
    }

    @Test("Truncate qualifies schema when TableInfo carries one")
    func truncateQualifiesSchema() {
        let builder = makeBuilder(tables: [TableInfo(name: "orders", type: .table, rowCount: nil, schema: "sales")])
        let stmts = builder.generate(truncates: ["orders"], deletes: [], options: [:], includeFKHandling: false)
        #expect(stmts == ["TRUNCATE TABLE \"sales\".\"orders\""])
    }

    // MARK: - Foreign key handling

    /// The statements come from the connected driver, not from a switch over DatabaseType. There
    /// used to be a built-in fallback here and a suite asserting it; the fallback was deleted and
    /// the suite went on asserting it, which is what put twelve cases in the quarantine file.
    @Test("Foreign key statements come from the driver")
    func foreignKeyStatementsComeFromTheDriver() {
        let builder = makeForeignKeyBuilder()
        #expect(builder.foreignKeyDisableStatements() == ["SET FOREIGN_KEY_CHECKS=0"])
        #expect(builder.foreignKeyEnableStatements() == ["SET FOREIGN_KEY_CHECKS=1"])
    }

    /// A driver that answers nothing produces nothing. Returning an empty list rather than guessing
    /// is the contract: the builder has no way to know a database's syntax that the driver does not
    /// tell it.
    @Test("A driver with no foreign key support produces no statements")
    func noForeignKeySupportProducesNothing() {
        let builder = makeBuilder(tables: [])
        #expect(builder.foreignKeyDisableStatements().isEmpty)
        #expect(builder.foreignKeyEnableStatements().isEmpty)
    }

    /// Disable first, then the work, then enable, with truncates and drops each in sorted order so
    /// one run of the same selection produces the same script every time.
    ///
    /// The connection is `.mysql` and the names come out double-quoted, which is the whole point:
    /// the identifier quoting comes from the driver, not from the DatabaseType. Reading it the
    /// other way round is what produced a suite of tests asserting MySQL backticks from a builder
    /// that has never known what MySQL is.
    @Test("Foreign key handling wraps the sorted truncates and drops")
    func foreignKeyHandlingWrapsSortedWork() {
        let builder = makeForeignKeyBuilder()
        let stmts = builder.generate(
            truncates: ["zebra", "apple"],
            deletes: ["yak", "bee"],
            options: [
                "apple": TableOperationOptions(ignoreForeignKeys: true),
                "zebra": TableOperationOptions(ignoreForeignKeys: true),
            ]
        )
        #expect(stmts == [
            "SET FOREIGN_KEY_CHECKS=0",
            "TRUNCATE TABLE \"apple\"",
            "TRUNCATE TABLE \"zebra\"",
            "DROP TABLE \"bee\"",
            "DROP TABLE \"yak\"",
            "SET FOREIGN_KEY_CHECKS=1",
        ])
    }

    /// No table asked to ignore foreign keys, so nothing wraps the work even though the driver
    /// would happily supply the statements.
    @Test("Nothing wraps the work when no table ignores foreign keys")
    func noWrappingWithoutTheOption() {
        let builder = makeForeignKeyBuilder()
        let stmts = builder.generate(truncates: ["apple"], deletes: [], options: [:])
        #expect(stmts == ["TRUNCATE TABLE \"apple\""])
    }
}
