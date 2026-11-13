import Foundation
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

public protocol DatabaseDriver: AnyObject, Sendable {
    func connect() async throws
    func disconnect() async throws
    func ping() async throws -> Bool
    var holdsSuspensionBlockingResource: Bool { get }

    func execute(query: String) async throws -> QueryResult
    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error>
    func cancelCurrentQuery() async throws

    /// Whether one request may carry a whole `GO` batch, so a script keeps its batch-scoped variables.
    var sendsBatchesWhole: Bool { get }

    /// How this session reads a string literal, where a server setting decides it, so a script is split the way the
    /// server will read it. Nil when the engine has no such setting or the session cannot say.
    func sessionLexicalFacts() async -> SQLSessionLexicalFacts?

    func fetchTables(schema: String?) async throws -> [TableInfo]
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo]
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo]
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo]
    func fetchDatabases() async throws -> [String]

    // The table in `database`, for an engine that names the database beside the schema (SQL Server's
    // `[db].[schema].[table]`), so the read never follows a `USE` the session ran. Any other engine reads as above.
    func fetchColumns(table: String, schema: String?, database: String?) async throws -> [ColumnInfo]
    func fetchIndexes(table: String, schema: String?, database: String?) async throws -> [IndexInfo]
    func fetchForeignKeys(table: String, schema: String?, database: String?) async throws -> [ForeignKeyInfo]

    // Runs a statement sent with `StreamOptions.enforcesReadOnly` in the engine's read-only mode, or refuses it.
    var enforcesReadOnlyMode: Bool { get }
    // Whether the mode can run now: its own transaction would end a transaction or a table lock the session holds.
    func entersReadOnlyMode() async -> Bool

    func switchDatabase(to name: String) async throws
    var supportsSchemas: Bool { get }
    func switchSchema(to name: String) async throws
    func fetchSchemas() async throws -> [String]
    var currentSchema: String? { get }

    var supportsTransactions: Bool { get }
    func beginTransaction() async throws
    func beginTransaction(mode: PluginTransactionAccessMode) async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws
    func sessionTransactionState() async -> DriverTransactionState

    var serverVersion: String? { get }

    // The database the session is on, for a driver that moves it itself: a MongoDB `use`, or a connection naming none.
    var currentDatabase: String? { get }

    // What `sessionLexicalFacts()` last answered, for a literal built without awaiting the session.
    var settledLexicalFacts: SQLSessionLexicalFacts? { get }

    func escapeStringLiteral(_ value: String) -> String
}

public extension DatabaseDriver {
    var holdsSuspensionBlockingResource: Bool { false }

    var sendsBatchesWhole: Bool { false }

    func sessionLexicalFacts() async -> SQLSessionLexicalFacts? { nil }

    func fetchColumns(table: String, schema: String?, database: String?) async throws -> [ColumnInfo] {
        try await fetchColumns(table: table, schema: schema)
    }

    func fetchIndexes(table: String, schema: String?, database: String?) async throws -> [IndexInfo] {
        try await fetchIndexes(table: table, schema: schema)
    }

    func fetchForeignKeys(table: String, schema: String?, database: String?) async throws -> [ForeignKeyInfo] {
        try await fetchForeignKeys(table: table, schema: schema)
    }

    var enforcesReadOnlyMode: Bool { false }

    func entersReadOnlyMode() async -> Bool {
        guard enforcesReadOnlyMode else { return false }
        return await sessionTransactionState() == .idle
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        try await beginTransaction()
    }

    func sessionTransactionState() async -> DriverTransactionState { .unknown }

    var currentDatabase: String? { nil }

    var settledLexicalFacts: SQLSessionLexicalFacts? { nil }

    func escapeStringLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value)
    }

    func executeStreaming(query: String, options: StreamOptions = .default) -> AsyncThrowingStream<StreamElement, Error> {
        QueryResultStreaming.stream(options: options) { try await self.execute(query: query) }
    }
}
