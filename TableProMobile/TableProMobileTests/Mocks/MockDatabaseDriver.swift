import Foundation
import TableProDatabase
import TableProModels

final class MockDatabaseDriver: DatabaseDriver, @unchecked Sendable {
    enum MockError: Error { case scripted }

    var scriptedExecuteResults: [Result<QueryResult, Error>] = []
    var scriptedColumns: [ColumnInfo] = []
    var scriptedForeignKeys: [ForeignKeyInfo] = []
    var scriptedTables: [TableInfo] = []
    var scriptedDatabases: [String] = []
    var scriptedSchemas: [String] = []

    private(set) var executedQueries: [String] = []
    private(set) var fetchColumnsCalls: Int = 0
    private(set) var fetchForeignKeysCalls: Int = 0

    var supportsSchemas: Bool = false
    var currentSchema: String? = nil
    var supportsTransactions: Bool = true
    var serverVersion: String? = "Mock 1.0"

    func connect() async throws {}
    func disconnect() async throws {}
    func ping() async throws -> Bool { true }
    func cancelCurrentQuery() async throws {}

    func execute(query: String) async throws -> QueryResult {
        executedQueries.append(query)
        guard !scriptedExecuteResults.isEmpty else {
            return QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)
        }
        switch scriptedExecuteResults.removeFirst() {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] { scriptedTables }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        fetchColumnsCalls += 1
        return scriptedColumns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        fetchForeignKeysCalls += 1
        return scriptedForeignKeys
    }

    func fetchDatabases() async throws -> [String] { scriptedDatabases }
    func fetchSchemas() async throws -> [String] { scriptedSchemas }
    func switchDatabase(to name: String) async throws {}
    func switchSchema(to name: String) async throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

final class MockSecureStore: SecureStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    var failNextStore = false

    func store(_ value: String, forKey key: String) throws {
        if failNextStore {
            failNextStore = false
            throw MockDatabaseDriver.MockError.scripted
        }
        storage[key] = value
    }

    func retrieve(forKey key: String) throws -> String? {
        storage[key]
    }

    func delete(forKey key: String) throws {
        storage.removeValue(forKey: key)
    }

    func seed(_ key: String, _ value: String) {
        storage[key] = value
    }
}
