import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
@testable import TableProMobile

final class MockDatabaseDriver: DatabaseDriver, @unchecked Sendable {
    enum MockError: Error { case scripted }

    var scriptedExecuteResults: [Result<QueryResult, Error>] = []
    var scriptedColumns: [ColumnInfo] = []
    var scriptedForeignKeys: [ForeignKeyInfo] = []
    var fetchForeignKeysError: Error?
    var fetchColumnsError: Error?
    var scriptedTables: [TableInfo] = []
    var scriptedDatabases: [String] = []
    // The database the driver says it is in, which may be named differently from the one the connection stores.
    var scriptedCurrentDatabase: String?
    // What `SELECT DATABASE()` and `current_schema()` answer; nil keeps the driver where it is.
    var scriptedSessionDatabase: String?
    var scriptedSessionSchema: String?
    private(set) var sessionDatabaseReads = 0
    var scriptedSchemas: [String] = []
    var scriptedTransactionState: DriverTransactionState = .unknown
    // Answered in order, one per call, before falling back to `scriptedTransactionState`.
    var scriptedTransactionStates: [DriverTransactionState] = []
    // Answered in order, one per call, then nil.
    var scriptedLexicalFacts: [SQLSessionLexicalFacts?] = []
    var pingError: Error?
    var connectError: Error?
    var switchDatabaseError: Error?
    var fetchTablesError: Error?
    var fetchDatabasesError: Error?
    var commitError: Error?
    var rollbackError: Error?

    private(set) var executedQueries: [String] = []
    private(set) var fetchColumnsCalls: Int = 0
    private(set) var fetchForeignKeysCalls: Int = 0
    private(set) var fetchColumnsSchemas: [String?] = []
    private(set) var fetchForeignKeysSchemas: [String?] = []
    private(set) var fetchColumnsDatabases: [String?] = []
    private(set) var fetchForeignKeysDatabases: [String?] = []
    private(set) var beganTransactionModes: [PluginTransactionAccessMode] = []
    private(set) var didBeginTransaction = false
    private(set) var didCommitTransaction = false
    private(set) var didRollbackTransaction = false
    private(set) var pingCount = 0
    private(set) var switchedDatabases: [String] = []
    private(set) var switchedSchemas: [String] = []
    private(set) var fetchTablesSchemas: [String?] = []
    private(set) var fetchSchemasCalls = 0
    private(set) var fetchDatabasesCalls = 0
    private(set) var transactionStateReads = 0

    var supportsSchemas: Bool = false
    var currentSchema: String?
    var supportsTransactions: Bool = true
    var serverVersion: String? = "Mock 1.0"
    var holdsSuspensionBlockingResource: Bool = false
    var sendsBatchesWhole: Bool = false
    var usesBackslashEscaping: Bool = false
    var enforcesReadOnlyMode: Bool = false

    func escapeStringLiteral(_ value: String) -> String {
        usesBackslashEscaping
            ? SQLEscaping.backslashStringLiteral(value)
            : SQLEscaping.ansiStringLiteral(value)
    }

    var beforeDisconnect: (@Sendable () async -> Void)?
    var beforeExecute: (@Sendable () async -> Void)?
    var beforeTransactionState: (@Sendable () async -> Void)?
    var beforeFetchTables: (@Sendable () async -> Void)?
    var beforeConnect: (@Sendable () async -> Void)?
    private(set) var connectSawCancellation = false

    func connect() async throws {
        await beforeConnect?()
        connectSawCancellation = Task.isCancelled
        if let connectError { throw connectError }
    }
    func disconnect() async throws {
        await beforeDisconnect?()
    }
    func ping() async throws -> Bool {
        pingCount += 1
        if let pingError { throw pingError }
        return true
    }
    func cancelCurrentQuery() async throws {}

    func execute(query: String) async throws -> QueryResult {
        await beforeExecute?()
        executedQueries.append(query)
        guard !scriptedExecuteResults.isEmpty else {
            return QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)
        }
        switch scriptedExecuteResults.removeFirst() {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        fetchTablesSchemas.append(schema)
        await beforeFetchTables?()
        if let fetchTablesError { throw fetchTablesError }
        return scriptedTables
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        try await fetchColumns(table: table, schema: schema, database: nil)
    }

    func fetchColumns(table: String, schema: String?, database: String?) async throws -> [ColumnInfo] {
        fetchColumnsCalls += 1
        fetchColumnsSchemas.append(schema)
        fetchColumnsDatabases.append(database)
        if let fetchColumnsError { throw fetchColumnsError }
        return scriptedColumns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        try await fetchForeignKeys(table: table, schema: schema, database: nil)
    }

    func fetchForeignKeys(table: String, schema: String?, database: String?) async throws -> [ForeignKeyInfo] {
        fetchForeignKeysCalls += 1
        fetchForeignKeysSchemas.append(schema)
        fetchForeignKeysDatabases.append(database)
        if let fetchForeignKeysError { throw fetchForeignKeysError }
        return scriptedForeignKeys
    }

    func fetchDatabases() async throws -> [String] {
        fetchDatabasesCalls += 1
        if let fetchDatabasesError { throw fetchDatabasesError }
        return scriptedDatabases
    }

    func fetchSchemas() async throws -> [String] {
        fetchSchemasCalls += 1
        return scriptedSchemas
    }
    var currentDatabase: String? { scriptedCurrentDatabase }

    var refusedDatabases: Set<String> = []

    func switchDatabase(to name: String) async throws {
        if let switchDatabaseError { throw switchDatabaseError }
        if refusedDatabases.contains(name) { throw MockError.scripted }
        switchedDatabases.append(name)
    }
    func switchSchema(to name: String) async throws {
        switchedSchemas.append(name)
        currentSchema = name
    }
    func beginTransaction() async throws { didBeginTransaction = true }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        beganTransactionModes.append(mode)
        didBeginTransaction = true
    }

    func commitTransaction() async throws {
        if let commitError { throw commitError }
        didCommitTransaction = true
    }

    func rollbackTransaction() async throws {
        if let rollbackError { throw rollbackError }
        didRollbackTransaction = true
    }

    func sessionLexicalFacts() async -> SQLSessionLexicalFacts? {
        guard !scriptedLexicalFacts.isEmpty else { return nil }
        return scriptedLexicalFacts.removeFirst()
    }

    func sessionTransactionState() async -> DriverTransactionState {
        transactionStateReads += 1
        await beforeTransactionState?()
        guard !scriptedTransactionStates.isEmpty else { return scriptedTransactionState }
        return scriptedTransactionStates.removeFirst()
    }
}

final class MockSecureStore: SecureStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    var failNextStore = false
    var refusesStores = false

    func store(_ value: String, forKey key: String) throws {
        if refusesStores {
            throw MockDatabaseDriver.MockError.scripted
        }
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

extension MockDatabaseDriver: SessionDatabaseReporting, SessionSchemaReporting {
    var reportsDatabaseWithoutStatement: Bool { false }

    func sessionDatabase() async throws -> String? {
        sessionDatabaseReads += 1
        return scriptedSessionDatabase
    }

    func settleCurrentSchema() async {
        guard let scriptedSessionSchema else { return }
        currentSchema = scriptedSessionSchema
    }
}
