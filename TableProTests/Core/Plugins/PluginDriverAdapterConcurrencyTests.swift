//
//  PluginDriverAdapterConcurrencyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("PluginDriverAdapter shares one instance per connection across tabs and windows")
struct PluginDriverAdapterConcurrencyTests {
    private static let columnTypeNames = [
        "VARCHAR(255)", "INT", "BIGINT", "DECIMAL(10,2)", "DATE", "TIMESTAMP",
        "DATETIME", "BOOLEAN", "BLOB", "JSON", "TEXT", "SMALLINT",
        "DOUBLE", "FLOAT", "CHAR(10)", "TINYINT"
    ]

    private func makeAdapter() -> PluginDriverAdapter {
        PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .mysql),
            pluginDriver: ConcurrentStubPluginDriver(columnTypeNames: Self.columnTypeNames)
        )
    }

    private func expectedTypes() -> [ColumnType] {
        let classifier = ColumnTypeClassifier()
        return Self.columnTypeNames.map { classifier.classify(rawTypeName: $0) }
    }

    @Test("Concurrent executeUserQuery calls on one adapter all map column types correctly")
    func concurrentUserQueriesMapColumnTypes() async throws {
        let adapter = makeAdapter()
        let expected = expectedTypes()

        let results = await withTaskGroup(of: [ColumnType].self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let result = try? await adapter.executeUserQuery(
                        query: "SELECT * FROM t",
                        rowCap: nil,
                        parameters: nil
                    )
                    return result?.columnTypes ?? []
                }
            }
            return await group.reduce(into: [[ColumnType]]()) { $0.append($1) }
        }

        #expect(results.count == 64)
        for columnTypes in results {
            #expect(columnTypes == expected)
        }
    }

    @Test("Concurrent execute and executeUserQuery calls share the type cache without losing entries")
    func concurrentMixedQueriesShareTypeCache() async throws {
        let adapter = makeAdapter()
        let expected = expectedTypes()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = try? await adapter.execute(query: "SELECT 1")
                    } else {
                        _ = try? await adapter.executeUserQuery(
                            query: "SELECT * FROM t",
                            rowCap: nil,
                            parameters: nil
                        )
                    }
                }
            }
        }

        let result = try await adapter.executeUserQuery(query: "SELECT * FROM t", rowCap: nil, parameters: nil)
        #expect(result.columnTypes == expected)
    }

    @Test("Reading status while connect and disconnect run concurrently stays a valid state")
    func concurrentStatusReadsStayValid() async throws {
        let adapter = makeAdapter()
        let valid: [ConnectionStatus] = [.disconnected, .connecting, .connected]

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        try? await adapter.connect()
                    } else {
                        adapter.disconnect()
                    }
                }
                group.addTask {
                    #expect(valid.contains(adapter.status))
                }
            }
        }
    }
}

private final class ConcurrentStubPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let columnTypeNames: [String]

    init(columnTypeNames: [String]) {
        self.columnTypeNames = columnTypeNames
    }

    private func makeResult() -> PluginQueryResult {
        PluginQueryResult(
            columns: columnTypeNames.indices.map { "col_\($0)" },
            columnTypeNames: columnTypeNames,
            rows: [],
            rowsAffected: 0,
            executionTime: 0.001
        )
    }

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        await Task.yield()
        return makeResult()
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        await Task.yield()
        return makeResult()
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?
    ) async throws -> PluginQueryResult {
        await Task.yield()
        return makeResult()
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchDatabases() async throws -> [String] { [] }
}
