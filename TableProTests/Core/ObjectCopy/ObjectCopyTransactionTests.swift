//
//  ObjectCopyTransactionTests.swift
//  TableProTests
//
//  The copy runs against a driver `withMetadataDriver` hands it, which is the connection's own
//  session driver on every engine that opts out of pooling (DuckDB, PGlite). A `BEGIN` of its own
//  over a transaction the user already had open aborts it on DuckDB and commits their pending work
//  on the engines that commit implicitly, so the copy joins the session's transaction instead, the
//  way `DataWriteExecutor`, `DatabaseManager+Principals` and `StructureRebuildPlanRunner` do.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class StubMetadataProvider: ScopedMetadataProviding {
    private let driver: DatabaseDriver

    init(driver: DatabaseDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

private final class RecordingCopyDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    private var transactions: [String] = []
    private var state: PluginSessionTransactionState

    init(sessionState: PluginSessionTransactionState) {
        state = sessionState
    }

    var executed: [String] { lock.withLock { statements } }
    var transactionEvents: [String] { lock.withLock { transactions } }

    var capabilities: PluginCapabilities { [] }
    var supportsTransactions: Bool { true }
    var supportsTransactionalDDL: Bool { true }

    func sessionTransactionState() async -> PluginSessionTransactionState { lock.withLock { state } }

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { statements.append(query) }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func beginTransaction() async throws { lock.withLock { transactions.append("begin") } }
    func commitTransaction() async throws { lock.withLock { transactions.append("commit") } }
    func rollbackTransaction() async throws { lock.withLock { transactions.append("rollback") } }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
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
}

@Suite("Object copy transactions")
@MainActor
struct ObjectCopyTransactionTests {
    private func endpoint(_ database: String) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: database, schema: nil),
            connectionName: "server",
            databaseType: .duckdb,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    /// A replacement: the drop and the create are one unit, which is what makes the structure phase
    /// want a transaction of its own.
    private func replacementPlan() -> ObjectCopyPlan {
        let selection = ObjectCopySelection(kind: .table, name: "orders", schema: nil)
        let step = ObjectCopyTableStep(
            selection: selection,
            dropStatements: [SyncStatement(sql: "DROP TABLE orders;", objectName: "orders", summary: "drop")],
            sequenceStatements: [],
            createStatements: [
                SyncStatement(sql: "CREATE TABLE orders (id INTEGER);", objectName: "orders", summary: "create"),
            ],
            truncateStatements: [],
            columns: [],
            primaryKeyColumns: ["id"],
            sourceQuery: "SELECT \"id\" FROM \"orders\"",
            targetTable: "orders",
            targetSchema: nil,
            estimatedRows: nil,
            copiesData: false,
            copiesIdentityColumn: false,
            note: nil
        )
        let request = ObjectCopyRequest(
            source: endpoint("app"),
            destination: .existing(endpoint("staging")),
            objects: [selection],
            content: .structure,
            existingPolicy: .replace,
            errorHandling: .stopAndRollback,
            wrapEachTableInTransaction: true
        )
        return ObjectCopyPlan(
            request: request,
            createsDatabase: false,
            tableSteps: [step],
            definitionSteps: [],
            schemaStatements: []
        )
    }

    private func run(sessionState: PluginSessionTransactionState) async throws -> (ObjectCopyRunResult, RecordingCopyDriver) {
        let plugin = RecordingCopyDriver(sessionState: sessionState)
        let connection = TestFixtures.makeConnection(type: .duckdb)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: plugin)
        let runner = ObjectCopyRunner(manager: StubMetadataProvider(driver: adapter), gate: AlwaysAllowGate())
        let result = try await runner.run(replacementPlan(), progress: ObjectCopyProgress(progress: Progress()))
        return (result, plugin)
    }

    @Test("An idle session lets the copy open its own transaction")
    func idleSessionKeepsTheCopysOwnTransaction() async throws {
        let (result, driver) = try await run(sessionState: .idle)

        #expect(driver.transactionEvents == ["begin", "commit"])
        #expect(driver.executed == ["DROP TABLE orders;", "CREATE TABLE orders (id INTEGER);"])
        #expect(result.pendingInSessionTransaction == false)
    }

    /// The statements still run: they join the transaction the user opened, and only the user can
    /// end it. Opening one over it is what aborted it on DuckDB.
    @Test("A session holding a transaction is joined rather than wrapped")
    func openSessionTransactionIsJoined() async throws {
        let (result, driver) = try await run(sessionState: .inTransaction)

        #expect(driver.transactionEvents.isEmpty)
        #expect(driver.executed == ["DROP TABLE orders;", "CREATE TABLE orders (id INTEGER);"])
        #expect(result.pendingInSessionTransaction)
    }

    /// A `LOCK TABLES` holds no transaction to commit, but a `START TRANSACTION` would release it,
    /// so the copy sends none.
    @Test("A session holding locks is joined too")
    func sessionLocksAreJoined() async throws {
        let (result, driver) = try await run(sessionState: .holdsSessionLocks)

        #expect(driver.transactionEvents.isEmpty)
        #expect(result.pendingInSessionTransaction)
    }
}
