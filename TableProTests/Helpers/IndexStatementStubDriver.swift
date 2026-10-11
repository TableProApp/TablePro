//
//  IndexStatementStubDriver.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit

internal final class IndexStatementStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    internal let indexSchema: String
    internal let writesIndexes: Bool

    internal init(indexSchema: String = "public", writesIndexes: Bool = true) {
        self.indexSchema = indexSchema
        self.writesIndexes = writesIndexes
    }

    internal var currentSchema: String? { indexSchema }

    internal func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }

    internal func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        guard writesIndexes else { return nil }
        return PostgreSQLIndexClauses.createStatement(
            for: index, qualifiedTable: "\(quoteIdentifier(indexSchema)).\(quoteIdentifier(table))"
        )
    }

    internal func generateDropIndexSQL(table: String, indexName: String) -> String? {
        guard writesIndexes else { return nil }
        return "DROP INDEX \(quoteIdentifier(indexSchema)).\(quoteIdentifier(indexName))"
    }

    internal func connect() async throws {}
    internal func disconnect() {}
    internal var isConnected: Bool { true }

    internal func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    internal func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    internal func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    internal func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    internal func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    internal func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    internal func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }

    internal func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    internal func fetchDatabases() async throws -> [String] { [] }

    internal func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}
