//
//  CopyInRecordingDriver.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit

// Records each text sent as a statement and each COPY sent through copy-in, with every piece of its data read.
final class CopyInRecordingDriver: DatabaseDriver, @unchecked Sendable {
    struct Copy: Equatable {
        let statement: String
        let data: Data
    }

    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    private let copiesIn: Bool
    private let lexicalState: PluginSessionLexicalState?
    private let lexicalStateAfterFirstStatement: PluginSessionLexicalState?
    private let lock = NSLock()
    private var statements: [String] = []
    private var copies: [Copy] = []

    // `lexicalStateAfterFirstStatement` is what the session reads once a statement ran, as after a `SET`.
    init(
        connection: DatabaseConnection,
        copiesIn: Bool,
        lexicalState: PluginSessionLexicalState? = nil,
        lexicalStateAfterFirstStatement: PluginSessionLexicalState? = nil
    ) {
        self.connection = connection
        self.copiesIn = copiesIn
        self.lexicalState = lexicalState
        self.lexicalStateAfterFirstStatement = lexicalStateAfterFirstStatement
    }

    var sentStatements: [String] {
        lock.withLock { statements }
    }

    var sentCopies: [Copy] {
        lock.withLock { copies }
    }

    var sessionLexicalState: PluginSessionLexicalState? {
        lock.withLock {
            guard let lexicalStateAfterFirstStatement, !(statements.isEmpty && copies.isEmpty) else { return lexicalState }
            return lexicalStateAfterFirstStatement
        }
    }

    var supportsCopyFromStandardInput: Bool { copiesIn }

    func copyFromStandardInput(
        statement: String,
        rows: PluginCopyData,
        context: PluginStatementContext?
    ) async throws -> QueryResult {
        guard copiesIn else { throw PluginDriverUnsupportedOperation.copyFromStandardInput }
        var data = Data()
        while let piece = try rows.nextPiece() {
            data.append(piece)
        }
        lock.withLock { copies.append(Copy(statement: statement, data: data)) }
        return Self.emptyResult
    }

    private static var emptyResult: QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    private func record(_ query: String) -> QueryResult {
        lock.withLock { statements.append(query) }
        return Self.emptyResult
    }

    func execute(query: String) async throws -> QueryResult { record(query) }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { record(query) }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        record(query)
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
