import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels

final class MockQueryBuildingDriver: DriverQueryBuilding, @unchecked Sendable {
    var scriptedColumns: [ColumnInfo] = []
    var scriptedRows: [[String?]] = []
    var scriptedCount: Int? = 0
    var scriptedValues: [Result<String?, Error>] = []

    private(set) var pageRequests: [(request: TableReadRequest, limit: Int, offset: Int)] = []
    private(set) var countRequests: [TableReadRequest] = []
    private(set) var lookups: [(table: String, column: String, key: [(column: String, value: String)])] = []
    private(set) var executedQueries: [String] = []

    var filterOperators: [FilterOperator] { [.equal, .contains] }

    func pageQuery(_ request: TableReadRequest, limit: Int, offset: Int) -> String {
        pageRequests.append((request, limit, offset))
        return "PAGE \(limit) \(offset)"
    }

    func rowCount(_ request: TableReadRequest) async throws -> Int? {
        countRequests.append(request)
        return scriptedCount
    }

    func storedValue(
        table: String,
        schema: String?,
        column: String,
        key: [(column: String, value: String)]
    ) async throws -> String? {
        lookups.append((table, column, key))
        guard !scriptedValues.isEmpty else { throw CellLookupError.rowNotFound }
        return try scriptedValues.removeFirst().get()
    }

    func connect() async throws {}
    func disconnect() async throws {}
    func ping() async throws -> Bool { true }
    func cancelCurrentQuery() async throws {}

    func execute(query: String) async throws -> QueryResult {
        executedQueries.append(query)
        return QueryResult(columns: scriptedColumns, rows: scriptedRows, rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] { scriptedColumns }
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] { [] }
    func fetchDatabases() async throws -> [String] { [] }
    func switchDatabase(to name: String) async throws {}
    var supportsSchemas: Bool { false }
    func switchSchema(to name: String) async throws {}
    func fetchSchemas() async throws -> [String] { [] }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { false }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    var serverVersion: String? { nil }
}
