//
//  PrimaryKeyConstraintLookupTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class LookupBaseDriver {
    var supportsTransactions: Bool { false }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}

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

private final class LookupDriver: LookupBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
    private(set) var executedQueries: [String] = []
    var answer: String?
    var failure: Error?
    let supportsSchemas: Bool
    let currentSchema: String?

    init(currentSchema: String?) {
        self.currentSchema = currentSchema
        self.supportsSchemas = currentSchema != nil
        super.init()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        if let failure { throw failure }
        let rows: [[PluginCellValue]] = answer.map { [[.text($0)]] } ?? []
        return PluginQueryResult(
            columns: ["CONSTRAINT_NAME"], columnTypeNames: ["TEXT"], rows: rows, rowsAffected: 0, executionTime: 0
        )
    }

    func switchDatabase(to database: String) async throws {}
}

@Suite("Primary key constraint lookup")
@MainActor
struct PrimaryKeyConstraintLookupTests {
    private static func adapter(_ driver: LookupDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .postgresql),
            pluginDriver: driver
        )
    }

    @Test("Asks the catalog for the key being dropped, in the driver's own schema")
    func asksForTheKeyInTheDriverSchema() async {
        let driver = LookupDriver(currentSchema: "reporting")
        driver.answer = "orders_pkey"

        let name = await PrimaryKeyConstraintLookup.constraintName(
            tableName: "sales",
            changes: [.modifyPrimaryKey(old: ["id"], new: ["id", "region"])],
            driver: Self.adapter(driver)
        )

        #expect(name == "orders_pkey")
        #expect(driver.executedQueries.count == 1)
        let query = driver.executedQueries.first ?? ""
        #expect(query.contains("TABLE_SCHEMA = 'reporting'"))
        #expect(query.contains("TABLE_NAME = 'sales'"))
        #expect(query.contains("CONSTRAINT_TYPE = 'PRIMARY KEY'"))
    }

    @Test("Escapes the table name as a string literal")
    func escapesTheTableName() async {
        let driver = LookupDriver(currentSchema: "public")

        _ = await PrimaryKeyConstraintLookup.constraintName(
            tableName: "o'rders",
            changes: [.modifyPrimaryKey(old: ["id"], new: [])],
            driver: Self.adapter(driver)
        )

        #expect(driver.executedQueries.first?.contains("TABLE_NAME = 'o''rders'") == true)
    }

    @Test("Asks nothing when no existing key is dropped")
    func asksNothingWithoutADrop() async {
        let driver = LookupDriver(currentSchema: "public")

        let added = await PrimaryKeyConstraintLookup.constraintName(
            tableName: "sales",
            changes: [.modifyPrimaryKey(old: [], new: ["id"])],
            driver: Self.adapter(driver)
        )
        let unrelated = await PrimaryKeyConstraintLookup.constraintName(
            tableName: "sales",
            changes: [.deleteColumn(EditableColumnDefinition.placeholder())],
            driver: Self.adapter(driver)
        )

        #expect(added == nil)
        #expect(unrelated == nil)
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("Asks nothing on an engine without schemas")
    func asksNothingWithoutSchemas() async {
        let driver = LookupDriver(currentSchema: nil)

        let name = await PrimaryKeyConstraintLookup.constraintName(
            tableName: "sales",
            changes: [.modifyPrimaryKey(old: ["id"], new: ["id", "region"])],
            driver: Self.adapter(driver)
        )

        #expect(name == nil)
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("A catalog that cannot answer leaves the name unknown")
    func failureLeavesTheNameUnknown() async {
        let driver = LookupDriver(currentSchema: "public")
        driver.failure = DatabaseError.queryFailed("relation does not exist")

        let name = await PrimaryKeyConstraintLookup.constraintName(
            tableName: "sales",
            changes: [.modifyPrimaryKey(old: ["id"], new: [])],
            driver: Self.adapter(driver)
        )

        #expect(name == nil)
        #expect(driver.executedQueries.count == 1)
    }
}
