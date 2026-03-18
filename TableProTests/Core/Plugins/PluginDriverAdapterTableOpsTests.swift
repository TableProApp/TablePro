//
//  PluginDriverAdapterTableOpsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubTableOpsDriver: PluginDatabaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var truncateOverride: ((String, String?, Bool) -> [String]?)?
    var dropOverride: ((String, String, String?, Bool) -> String?)?

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        truncateOverride?(table, schema, cascade)
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        dropOverride?(name, objectType, schema, cascade)
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchRowCount(query: String) async throws -> Int { 0 }
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
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

@Suite("PluginDriverAdapter table operations")
struct PluginDriverAdapterTableOpsTests {
    private func makeAdapter(driver: StubTableOpsDriver) -> PluginDriverAdapter {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        return PluginDriverAdapter(connection: connection, pluginDriver: driver)
    }

    // MARK: - dropObjectStatement

    @Test("Fallback produces DROP TABLE with quoted name")
    func dropTableFallback() {
        let adapter = makeAdapter(driver: StubTableOpsDriver())
        let result = adapter.dropObjectStatement(name: "users", objectType: "TABLE", schema: nil, cascade: false)
        #expect(result == "DROP TABLE \"users\"")
    }

    @Test("Fallback produces DROP VIEW for views")
    func dropViewFallback() {
        let adapter = makeAdapter(driver: StubTableOpsDriver())
        let result = adapter.dropObjectStatement(name: "active_users", objectType: "VIEW", schema: nil, cascade: false)
        #expect(result == "DROP VIEW \"active_users\"")
    }

    @Test("Fallback appends CASCADE when requested")
    func dropWithCascade() {
        let adapter = makeAdapter(driver: StubTableOpsDriver())
        let result = adapter.dropObjectStatement(name: "orders", objectType: "TABLE", schema: nil, cascade: true)
        #expect(result == "DROP TABLE \"orders\" CASCADE")
    }

    @Test("Fallback includes schema qualification")
    func dropWithSchema() {
        let adapter = makeAdapter(driver: StubTableOpsDriver())
        let result = adapter.dropObjectStatement(name: "users", objectType: "TABLE", schema: "public", cascade: false)
        #expect(result == "DROP TABLE \"public\".\"users\"")
    }

    @Test("Plugin override is returned when non-nil")
    func dropPluginOverride() {
        let driver = StubTableOpsDriver()
        driver.dropOverride = { name, objectType, _, _ in
            "DROP \(objectType) IF EXISTS `\(name)`"
        }
        let adapter = makeAdapter(driver: driver)
        let result = adapter.dropObjectStatement(name: "users", objectType: "TABLE", schema: nil, cascade: false)
        #expect(result == "DROP TABLE IF EXISTS `users`")
    }

    // MARK: - truncateTableStatements

    @Test("Fallback produces TRUNCATE TABLE with quoted name")
    func truncateFallback() {
        let adapter = makeAdapter(driver: StubTableOpsDriver())
        let result = adapter.truncateTableStatements(table: "users", schema: nil, cascade: false)
        #expect(result == ["TRUNCATE TABLE \"users\""])
    }

    @Test("Fallback appends CASCADE when requested")
    func truncateWithCascade() {
        let adapter = makeAdapter(driver: StubTableOpsDriver())
        let result = adapter.truncateTableStatements(table: "orders", schema: nil, cascade: true)
        #expect(result == ["TRUNCATE TABLE \"orders\" CASCADE"])
    }

    @Test("Fallback includes schema qualification")
    func truncateWithSchema() {
        let adapter = makeAdapter(driver: StubTableOpsDriver())
        let result = adapter.truncateTableStatements(table: "users", schema: "public", cascade: false)
        #expect(result == ["TRUNCATE TABLE \"public\".\"users\""])
    }

    @Test("Plugin override is returned when non-nil")
    func truncatePluginOverride() {
        let driver = StubTableOpsDriver()
        driver.truncateOverride = { table, _, _ in
            ["DELETE FROM `\(table)`", "ALTER TABLE `\(table)` AUTO_INCREMENT = 1"]
        }
        let adapter = makeAdapter(driver: driver)
        let result = adapter.truncateTableStatements(table: "users", schema: nil, cascade: false)
        #expect(result == ["DELETE FROM `users`", "ALTER TABLE `users` AUTO_INCREMENT = 1"])
    }
}
