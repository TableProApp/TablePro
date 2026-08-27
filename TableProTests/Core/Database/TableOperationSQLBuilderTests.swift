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
    private func ref(
        _ name: String,
        _ type: TableInfo.TableType = .table,
        schema: String? = nil,
        rowSchema: String? = nil,
        database: String? = nil
    ) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: database,
            schema: rowSchema,
            table: TableInfo(name: name, type: type, rowCount: nil, schema: schema)
        )
    }

    private func makeForeignKeyBuilder() -> TableOperationSQLBuilder {
        let connection = DatabaseConnection(name: "Test", type: .mysql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: StubForeignKeyDriver())
        return TableOperationSQLBuilder(adapterProvider: { adapter })
    }

    private func makeBuilder() -> TableOperationSQLBuilder {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: StubDropDriver())
        return TableOperationSQLBuilder(adapterProvider: { adapter })
    }

    @Test("Materialized view drops with DROP MATERIALIZED VIEW")
    func dropsMaterializedView() {
        let stmts = makeBuilder().generate(
            truncates: [], deletes: [ref("daily_sales", .materializedView, schema: "public")],
            options: [:], includeFKHandling: false
        )
        #expect(stmts == ["DROP MATERIALIZED VIEW \"public\".\"daily_sales\""])
    }

    @Test("View drops with DROP VIEW")
    func dropsView() {
        let stmts = makeBuilder().generate(
            truncates: [], deletes: [ref("active_users", .view)], options: [:], includeFKHandling: false
        )
        #expect(stmts == ["DROP VIEW \"active_users\""])
    }

    @Test("Foreign table drops with DROP FOREIGN TABLE")
    func dropsForeignTable() {
        let stmts = makeBuilder().generate(
            truncates: [], deletes: [ref("remote_orders", .foreignTable)], options: [:], includeFKHandling: false
        )
        #expect(stmts == ["DROP FOREIGN TABLE \"remote_orders\""])
    }

    @Test("External table drops with DROP TABLE")
    func dropsExternalTable() {
        let stmts = makeBuilder().generate(
            truncates: [], deletes: [ref("customers", .externalTable)], options: [:], includeFKHandling: false
        )
        #expect(stmts == ["DROP TABLE \"customers\""])
    }

    @Test("Plain table drops with DROP TABLE")
    func dropsTable() {
        let stmts = makeBuilder().generate(
            truncates: [], deletes: [ref("orders")], options: [:], includeFKHandling: false
        )
        #expect(stmts == ["DROP TABLE \"orders\""])
    }

    @Test("System table drops with DROP TABLE")
    func dropsSystemTable() {
        let stmts = makeBuilder().generate(
            truncates: [], deletes: [ref("pg_stats", .systemTable)], options: [:], includeFKHandling: false
        )
        #expect(stmts == ["DROP TABLE \"pg_stats\""])
    }

    /// The queued row carries its own type and schema, so a tree that publishes no flat table list
    /// still produces the right statement. It used to look the object up in that list, which is
    /// empty on every engine whose tree is per-schema: a view on Oracle came out as an unqualified
    /// `DROP TABLE` and raised ORA-00942, and a table of the same name in the login schema was a
    /// live target.
    @Test("A row under a schema node drops qualified and typed with no table cache")
    func hierarchicalRowKeepsTypeAndSchema() {
        let stmts = makeBuilder().generate(
            truncates: [],
            deletes: [ref("EMP_VIEW", .view, rowSchema: "HR")],
            options: [:],
            includeFKHandling: false
        )
        #expect(stmts == ["DROP VIEW \"HR\".\"EMP_VIEW\""])
    }

    @Test("Cascade applies to materialized view drops")
    func cascadeAppliesToMaterializedView() {
        let target = ref("daily_sales", .materializedView)
        let stmts = makeBuilder().generate(
            truncates: [], deletes: [target],
            options: [target: TableOperationOptions(cascade: true)], includeFKHandling: false
        )
        #expect(stmts == ["DROP MATERIALIZED VIEW \"daily_sales\" CASCADE"])
    }

    @Test("Drop qualifies schema when TableInfo carries one")
    func qualifiesSchema() {
        let stmts = makeBuilder().generate(
            truncates: [], deletes: [ref("orders", schema: "sales")], options: [:], includeFKHandling: false
        )
        #expect(stmts == ["DROP TABLE \"sales\".\"orders\""])
    }

    @Test("Truncate qualifies schema when TableInfo carries one")
    func truncateQualifiesSchema() {
        let stmts = makeBuilder().generate(
            truncates: [ref("orders", schema: "sales")], deletes: [], options: [:], includeFKHandling: false
        )
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
        let builder = makeBuilder()
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
        let apple = ref("apple")
        let zebra = ref("zebra")
        let stmts = makeForeignKeyBuilder().generate(
            truncates: [zebra, apple],
            deletes: [ref("yak"), ref("bee")],
            options: [
                apple: TableOperationOptions(ignoreForeignKeys: true),
                zebra: TableOperationOptions(ignoreForeignKeys: true),
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
}
