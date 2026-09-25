//
//  ResultSetBatchAdapterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class BatchAnsweringDriver: PluginDatabaseDriver, @unchecked Sendable {
    let declaresBatches: Bool
    private(set) var sentBatches: [(query: String, rowCap: Int?, parameters: [PluginCellValue]?)] = []

    init(declaresBatches: Bool) {
        self.declaresBatches = declaresBatches
    }

    var capabilities: PluginCapabilities {
        declaresBatches ? [.resultSetBatches] : []
    }

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func executeBatch(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginBatchResult? {
        guard declaresBatches else { return nil }
        sentBatches.append((query, rowCap, parameters))
        return PluginBatchResult(
            resultSets: [
                PluginQueryResult(
                    columns: ["S/N", "model"],
                    columnTypeNames: ["NVARCHAR", "NVARCHAR"],
                    rows: [[.text("2404GQV000066A00105"), .text("X1")]],
                    rowsAffected: 0,
                    executionTime: 0.01
                ),
                PluginQueryResult(
                    columns: ["sn_code", "seen_at"],
                    columnTypeNames: ["NVARCHAR", "DATETIME2"],
                    rows: [],
                    rowsAffected: 0,
                    executionTime: 0.01
                ),
            ],
            rowsAffected: 3,
            errors: [
                PluginBatchError(
                    message: "Invalid object name 'missing'.",
                    code: 208,
                    line: 9,
                    procedure: nil,
                    precedingResultSetCount: 2
                ),
            ],
            discardedResultSetCount: 1,
            executionTime: 0.05
        )
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

struct ResultSetBatchAdapterTests {
    private func makeAdapter(declaresBatches: Bool) -> (PluginDriverAdapter, BatchAnsweringDriver) {
        let driver = BatchAnsweringDriver(declaresBatches: declaresBatches)
        let adapter = PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: .mssql), pluginDriver: driver)
        return (adapter, driver)
    }

    @Test("The adapter reports the driver's batch capability")
    func capabilityIsReported() {
        #expect(makeAdapter(declaresBatches: true).0.supportsResultSetBatches)
        #expect(!makeAdapter(declaresBatches: false).0.supportsResultSetBatches)
    }

    @Test("Every result set keeps its own columns, and the counts and errors come through")
    func batchIsMapped() async throws {
        let (adapter, driver) = makeAdapter(declaresBatches: true)
        let batch = try #require(try await adapter.executeBatch(
            query: "DECLARE @sn NVARCHAR(50) = N'x'; SELECT 1; SELECT 2",
            rowCap: 500,
            parameters: ["x"]
        ))

        #expect(batch.resultSets.map(\.columns) == [["S/N", "model"], ["sn_code", "seen_at"]])
        #expect(batch.resultSets.first?.rows.count == 1)
        #expect(batch.resultSets.map { $0.columnTypes.count } == [2, 2])
        #expect(batch.rowsAffected == 3)
        #expect(batch.discardedResultSetCount == 1)
        #expect(batch.errors.first?.code == 208)
        #expect(batch.errors.first?.precedingResultSetCount == 2)
        #expect(driver.sentBatches.first?.rowCap == 500)
        #expect(driver.sentBatches.first?.parameters?.count == 1)
    }

    @Test("A driver that declines a batch answers nil")
    func decliningDriverAnswersNil() async throws {
        let (adapter, _) = makeAdapter(declaresBatches: false)
        let batch = try await adapter.executeBatch(query: "SELECT 1; SELECT 2", rowCap: nil, parameters: nil)
        #expect(batch == nil)
    }
}
