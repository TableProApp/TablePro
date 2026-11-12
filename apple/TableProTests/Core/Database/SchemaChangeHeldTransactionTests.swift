//
//  SchemaChangeHeldTransactionTests.swift
//  TableProTests
//
//  On the session driver an app-owned BEGIN joins what a tab left open and its COMMIT ends it, so a
//  schema change there runs inside that transaction. On a pooled connection it can wait on the
//  transaction's locks, so it asks first.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class HeldDDLDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PluginSessionTransactionState = .idle
    private var sent: [String] = []

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }
    var supportsTransactions: Bool { true }
    var supportsTransactionalDDL: Bool { true }

    var state: PluginSessionTransactionState {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var statements: [String] { lock.withLock { sent } }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock {
            sent.append(query)
            switch query.uppercased() {
            case "BEGIN": current = .inTransaction
            case "COMMIT", "ROLLBACK": current = .idle
            default: break
            }
        }
        return .empty
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { state }

    func switchDatabase(to database: String) async throws {}
}

@Suite("Schema changes beside an open transaction", .serialized)
@MainActor
struct SchemaChangeHeldTransactionTests {
    private static let first = "ALTER TABLE orders ADD COLUMN a INT;"
    private static let second = "ALTER TABLE orders ADD COLUMN b INT;"

    private static func injectSession(type: DatabaseType) -> (DatabaseConnection, HeldDDLDriver, DatabaseDriver) {
        let connection = TestFixtures.makeConnection(database: "orders", type: type)
        let driver = HeldDDLDriver()
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        var session = ConnectionSession(connection: connection, driver: adapter)
        session.browseDatabase = "orders"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver, adapter)
    }

    private static func tearDown(_ connection: DatabaseConnection) {
        MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private static func scope(_ connection: DatabaseConnection) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "orders", schema: nil)
    }

    private static func script() -> SchemaChangeScript {
        SchemaChangeScript(
            tableName: "orders",
            statements: [first, second].map { SchemaStatement(sql: $0, description: $0, isDestructive: false) },
            operations: [],
            review: PluginSchemaChangeReview()
        )
    }

    @Test("On the session driver a Structure save inside an open transaction joins it")
    func sessionRouteSaveJoinsTheOpenTransaction() async throws {
        let (connection, driver, _) = Self.injectSession(type: .duckdb)
        defer { Self.tearDown(connection) }
        driver.state = .inTransaction

        try await DatabaseManager.shared.executeSchemaChanges(
            Self.script(), databaseType: .duckdb, scope: Self.scope(connection), gate: AlwaysAllowGate()
        )

        #expect(driver.statements == [Self.first, Self.second])
        #expect(driver.state == .inTransaction)
    }

    @Test("On the session driver an idle Structure save keeps its own transaction")
    func sessionRouteIdleSaveWraps() async throws {
        let (connection, driver, _) = Self.injectSession(type: .duckdb)
        defer { Self.tearDown(connection) }

        try await DatabaseManager.shared.executeSchemaChanges(
            Self.script(), databaseType: .duckdb, scope: Self.scope(connection), gate: AlwaysAllowGate()
        )

        #expect(driver.statements == ["BEGIN", Self.first, Self.second, "COMMIT"])
    }

    @Test("On the session driver Create Table inside an open transaction joins it")
    func sessionRouteCreateTableJoins() async throws {
        let (connection, driver, _) = Self.injectSession(type: .duckdb)
        defer { Self.tearDown(connection) }
        driver.state = .inTransaction

        try await DatabaseManager.shared.executeCreateTable(
            statements: [Self.first, Self.second], databaseType: .duckdb, scope: Self.scope(connection),
            gate: AlwaysAllowGate()
        )

        #expect(driver.statements == [Self.first, Self.second])
    }

    @Test("A trigger edit that joins an open transaction sends no BEGIN or COMMIT")
    func joinedTriggerEditSendsNoTransaction() async throws {
        let connection = TestFixtures.makeConnection(type: .duckdb)
        let driver = HeldDDLDriver()
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)

        try await TriggerEditing.runInTransaction(driver: adapter, dropSQL: "DROP TRIGGER t", sql: "CREATE TRIGGER t", wraps: false)

        #expect(driver.statements == ["DROP TRIGGER t", "CREATE TRIGGER t"])
    }

    @Test("A pooled save beside an open transaction asks first, and a Cancel runs nothing")
    func pooledSaveAsksBesideAHold() async throws {
        let (connection, _, sessionAdapter) = Self.injectSession(type: .mysql)
        defer { Self.tearDown(connection) }
        let pooled = HeldDDLDriver()
        let pooledAdapter = PluginDriverAdapter(connection: connection, pluginDriver: pooled)
        try await pooledAdapter.connect()
        MetadataConnectionPool.shared.injectEntry(pooledAdapter, scope: Self.scope(connection))
        DatabaseManager.shared.sessionTransactions.record(
            .inTransaction, on: sessionAdapter, for: .init(connectionId: connection.id, lane: nil)
        )

        await #expect(throws: ExecutionGateError.self) {
            try await DatabaseManager.shared.executeSchemaChanges(
                Self.script(), databaseType: .mysql, scope: Self.scope(connection), gate: AlwaysAllowGate(),
                holdConfirmation: { false }
            )
        }
        #expect(pooled.statements.isEmpty)

        try await DatabaseManager.shared.executeSchemaChanges(
            Self.script(), databaseType: .mysql, scope: Self.scope(connection), gate: AlwaysAllowGate(),
            holdConfirmation: { true }
        )
        #expect(pooled.statements == ["BEGIN", Self.first, Self.second, "COMMIT"])
    }
}
