import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels

final class MockKeyContentsDriver: KeyContentsBrowsing, @unchecked Sendable {
    struct PageRequest: Equatable {
        let key: String
        let limit: Int
        let offset: Int
    }

    var scriptedPages: [Result<KeyContentsPage, Error>] = []

    private(set) var pageRequests: [PageRequest] = []
    private(set) var executedQueries: [String] = []
    private(set) var fetchColumnsCalls = 0
    private(set) var fetchForeignKeysCalls = 0

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { false }
    var serverVersion: String? { nil }

    func keyContentsPage(ofKey key: String, limit: Int, offset: Int) async throws -> KeyContentsPage {
        pageRequests.append(PageRequest(key: key, limit: limit, offset: offset))
        guard !scriptedPages.isEmpty else {
            return KeyContentsPage(
                result: QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0),
                totalCount: 0
            )
        }
        return try scriptedPages.removeFirst().get()
    }

    func connect() async throws {}
    func disconnect() async throws {}
    func ping() async throws -> Bool { true }
    func cancelCurrentQuery() async throws {}

    func execute(query: String) async throws -> QueryResult {
        executedQueries.append(query)
        return QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        fetchColumnsCalls += 1
        return []
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        fetchForeignKeysCalls += 1
        return []
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchSchemas() async throws -> [String] { [] }
    func switchDatabase(to name: String) async throws {}
    func switchSchema(to name: String) async throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}
