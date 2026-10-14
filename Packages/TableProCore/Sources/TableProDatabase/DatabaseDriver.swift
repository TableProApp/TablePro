import Foundation
import TableProModels
import TableProPluginKit
import TableProSQLGrammar

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

    func escapeStringLiteral(_ value: String) -> String
}

public extension DatabaseDriver {
    var holdsSuspensionBlockingResource: Bool { false }

    var sendsBatchesWhole: Bool { false }

    func sessionLexicalFacts() async -> SQLSessionLexicalFacts? { nil }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        try await beginTransaction()
    }

    func sessionTransactionState() async -> DriverTransactionState { .unknown }

    func escapeStringLiteral(_ value: String) -> String {
        SQLEscaping.ansiStringLiteral(value)
    }

    func executeStreaming(query: String, options: StreamOptions = .default) -> AsyncThrowingStream<StreamElement, Error> {
        QueryResultStreaming.stream(options: options) { try await self.execute(query: query) }
    }
}
