//
//  PluginDriverAdapterResultMappingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubResultDriver: PluginDatabaseDriver {
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }
    let stubbedResult: PluginQueryResult

    init(stubbedResult: PluginQueryResult) {
        self.stubbedResult = stubbedResult
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        stubbedResult
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

@Suite("PluginDriverAdapter result mapping")
struct PluginDriverAdapterResultMappingTests {
    @Test("execute maps PluginQueryResult at plugin boundary")
    func executeMapsPluginQueryResult() async throws {
        let pluginResult = PluginQueryResult(
            columns: ["id", "payload", "blob"],
            columnTypeNames: ["INTEGER", "JSON", "BLOB"],
            rows: [[.text("1"), .null, .bytes(Data([0xAB, 0xCD]))]],
            rowsAffected: 1,
            executionTime: 0.042,
            isTruncated: true,
            statusMessage: "OK"
        )
        let driver = StubResultDriver(stubbedResult: pluginResult)
        let adapter = PluginDriverAdapter(
            connection: DatabaseConnection(name: "Test", type: .postgresql),
            pluginDriver: driver
        )

        let result = try await adapter.execute(query: "select 1")

        #expect(result.columns == ["id", "payload", "blob"])
        #expect(result.columnTypes[0] == .integer(rawType: "INTEGER"))
        #expect(result.columnTypes[1] == .json(rawType: "JSON"))
        #expect(result.columnTypes[2] == .blob(rawType: "BLOB"))
        #expect(result.rows == [[.text("1"), .null, .bytes(Data([0xAB, 0xCD]))]])
        #expect(result.rowsAffected == 1)
        #expect(result.executionTime == 0.042)
        #expect(result.isTruncated)
        #expect(result.statusMessage == "OK")
    }
}
