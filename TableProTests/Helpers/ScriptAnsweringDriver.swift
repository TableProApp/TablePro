//
//  ScriptAnsweringDriver.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit

/// A driver that answers a batch the way the SQL Server driver does, from whatever each test says the batch returned,
/// and records every text that reached it and through which call.
final class ScriptAnsweringDriver: DatabaseDriver, @unchecked Sendable {
    struct SentBatch: Equatable {
        let sql: String
        let rowCap: Int?
    }

    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    private let sendsBatchesWhole: Bool
    private let transactionState: PluginSessionTransactionState
    private let answer: @Sendable (String) -> QueryBatchResult
    private let lock = NSLock()
    private var batches: [SentBatch] = []
    private var statements: [String] = []

    init(
        connection: DatabaseConnection,
        sendsBatchesWhole: Bool = true,
        transactionState: PluginSessionTransactionState = .idle,
        answer: @escaping @Sendable (String) -> QueryBatchResult = { _ in .empty }
    ) {
        self.connection = connection
        self.sendsBatchesWhole = sendsBatchesWhole
        self.transactionState = transactionState
        self.answer = answer
    }

    var sentBatches: [SentBatch] {
        lock.withLock { batches }
    }

    var sentStatements: [String] {
        lock.withLock { statements }
    }

    var supportsResultSetBatches: Bool { sendsBatchesWhole }

    func executeBatch(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryBatchResult? {
        guard sendsBatchesWhole else { return nil }
        lock.withLock { batches.append(SentBatch(sql: query, rowCap: rowCap)) }
        return answer(query)
    }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        transactionState
    }

    private func record(_ query: String) -> QueryResult {
        lock.withLock { statements.append(query) }
        return Self.resultSet(columns: ["n"], rows: [["1"]])
    }

    func execute(query: String) async throws -> QueryResult { record(query) }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { record(query) }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        record(query)
    }

    static func resultSet(columns: [String], rows: [[String]], isTruncated: Bool = false) -> QueryResult {
        var result = QueryResult(
            columns: columns,
            columnTypes: columns.map { _ in .text(rawType: nil) },
            rows: rows.map { row in row.map(PluginCellValue.fromOptional) },
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
        result.isTruncated = isTruncated
        return result
    }

    static func batch(
        _ resultSets: [QueryResult],
        rowsAffected: Int = 0,
        errors: [PluginBatchError] = []
    ) -> QueryBatchResult {
        QueryBatchResult(
            resultSets: resultSets,
            rowsAffected: rowsAffected,
            errors: errors,
            discardedResultSetCount: 0,
            executionTime: 0
        )
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func ping() async throws {}
    func cancelQuery() throws {}
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database,
            name: database,
            tableCount: nil,
            sizeBytes: nil,
            lastAccessed: nil,
            isSystemDatabase: false,
            icon: "cylinder"
        )
    }

    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: nil,
            comment: nil,
            engine: nil,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    func fetchViewDefinition(view: String) async throws -> String { "" }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}
