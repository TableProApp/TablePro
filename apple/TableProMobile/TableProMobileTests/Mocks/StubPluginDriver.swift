import Foundation
import TableProPluginKit

final class StubPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    var scriptedResult: PluginQueryResult = .empty
    var answersBoundedReads = true
    var hasTransactions = false
    var scriptedColumns: [PluginColumnInfo] = []

    private(set) var boundedQueries: [(query: String, rowCap: Int)] = []
    private(set) var plainQueries: [String] = []
    private(set) var parameterizedQueries: [(query: String, parameters: [PluginCellValue])] = []
    private(set) var generatedChanges: [PluginRowChange] = []
    private(set) var generatedInserts: [Int: [PluginCellValue]] = [:]
    private(set) var generatedColumns: [String] = []
    private(set) var appliedQueryTimeouts: [Int] = []

    func connect() async throws {}

    func applyQueryTimeout(_ seconds: Int) async throws {
        appliedQueryTimeouts.append(seconds)
    }
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        plainQueries.append(query)
        return scriptedResult
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        parameterizedQueries.append((query, parameters))
        return scriptedResult
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        guard answersBoundedReads else { return nil }
        boundedQueries.append((query, rowCap))
        return scriptedResult
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { scriptedColumns }
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

    var supportsTransactions: Bool { hasTransactions }

    func escapeStringLiteral(_ value: String) -> String {
        "escaped:\(value)"
    }

    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        generatedChanges.append(contentsOf: changes)
        generatedInserts.merge(insertedRowData) { _, new in new }
        generatedColumns = columns
        return changes.map { change in
            (statement: "WRITE \(change.type) \(table)", parameters: change.originalRow ?? insertedRowData[change.rowIndex] ?? [])
        }
    }
}
