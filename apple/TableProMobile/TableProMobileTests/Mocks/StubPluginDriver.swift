import Foundation
import TableProPluginKit

final class StubPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    var scriptedResult: PluginQueryResult = .empty
    var answersBoundedReads = true
    var hasTransactions = false
    var scriptedColumns: [PluginColumnInfo] = []
    // How many rows each row lookup finds, in order: the check before a change, then the writer's lookup when it runs.
    var rowCounts: [Int] = [1, 1, 0]
    // How many rows each writer's check after a write finds; a row means the write did not land.
    var checkRows: [Int] = []
    var onFetchTables: (@Sendable () async -> Void)?
    var currentDb = ""
    private(set) var databasesAtExecute: [String] = []

    private(set) var boundedQueries: [(query: String, rowCap: Int)] = []
    private(set) var plainQueries: [String] = []
    private(set) var parameterizedQueries: [(query: String, parameters: [PluginCellValue])] = []
    private(set) var generatedChanges: [PluginRowChange] = []
    private(set) var generatedInserts: [Int: [PluginCellValue]] = [:]
    private(set) var generatedColumns: [String] = []
    private(set) var appliedQueryTimeouts: [Int] = []
    private(set) var cancelQueryCalls = 0
    private(set) var rowLookups: [(query: String, parameters: [PluginCellValue])] = []
    private(set) var checks: [(query: String, parameters: [PluginCellValue])] = []
    private(set) var contexts: [PluginStatementContext] = []

    func connect() async throws {}

    func applyQueryTimeout(_ seconds: Int) async throws {
        appliedQueryTimeouts.append(seconds)
    }
    func disconnect() {}

    func cancelQuery() throws {
        cancelQueryCalls += 1
    }

    func execute(query: String) async throws -> PluginQueryResult {
        plainQueries.append(query)
        databasesAtExecute.append(currentDb)
        return scriptedResult
    }

    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        contexts.append(context)
        return try await execute(query: query)
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        contexts.append(context)
        return try await executeUserQuery(query: query, rowCap: rowCap, parameters: parameters)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        if query.hasPrefix("LOOKUP ") || (query.hasPrefix("SELECT ") && query.hasSuffix(" LIMIT 2")) {
            rowLookups.append((query, parameters))
            let count = rowCounts.isEmpty ? 0 : rowCounts.removeFirst()
            return PluginQueryResult(
                columns: ["_part"], columnTypeNames: ["String"],
                rows: Array(repeating: [.text("all_1_1_0")], count: count),
                rowsAffected: 0, timing: PluginQueryTiming(total: 0)
            )
        }
        if query.hasPrefix("CHECK ") {
            checks.append((query, parameters))
            let count = checkRows.isEmpty ? 0 : checkRows.removeFirst()
            return PluginQueryResult(
                columns: ["1"], columnTypeNames: ["UInt8"], rows: Array(repeating: [.text("1")], count: count),
                rowsAffected: 0, timing: PluginQueryTiming(total: 0)
            )
        }
        parameterizedQueries.append((query, parameters))
        return scriptedResult
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        guard answersBoundedReads else { return nil }
        boundedQueries.append((query, rowCap))
        return scriptedResult
    }

    func switchDatabase(to database: String) async throws {
        currentDb = database
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        await onFetchTables?()
        return []
    }
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

    // Like ClickHouse's writer: an update or delete finds its row and is pinned to it, then checked.
    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        let statements = generateStatements(
            table: table, columns: columns, primaryKeyColumns: primaryKeyColumns, changes: changes,
            insertedRowData: insertedRowData, deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        ) ?? []
        return zip(changes, statements).map { change, statement in
            let row = change.originalRow ?? []
            let lookup = change.type == .insert ? nil : PluginRowLookup(
                query: "LOOKUP \(change.type) \(table)",
                parameters: row,
                rowCount: 1,
                pinsRows: true,
                check: "CHECK \(change.type) \(table)",
                checkParameters: row + change.cellChanges.map(\.newValue)
            )
            return PluginRowWrite(
                statement: statement.statement, parameters: statement.parameters, rowIndices: [change.rowIndex], lookup: lookup
            )
        }
    }
}
