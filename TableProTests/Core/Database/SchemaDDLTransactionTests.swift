//
//  SchemaDDLTransactionTests.swift
//  TableProTests
//
//  A Structure save and a Create Table run their DDL inside BEGIN and COMMIT only where the engine
//  rolls DDL back. Teradata answers any statement after DDL inside a transaction with error 3932.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class TransactionalDDLBaseDriver {
    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}

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

private final class TransactionalDDLDriver: TransactionalDDLBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
    let supportsTransactions: Bool
    let supportsTransactionalDDL: Bool
    var failingStatement: String?
    private(set) var executedQueries: [String] = []

    init(transactions: Bool, transactionalDDL: Bool) {
        supportsTransactions = transactions
        supportsTransactionalDDL = transactionalDDL
        super.init()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        if let failingStatement, query == failingStatement {
            throw DatabaseError.queryFailed("statement refused")
        }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func switchDatabase(to database: String) async throws {}
    func switchSchema(to schema: String) async throws {}
}

@Suite("Schema DDL transactions", .serialized)
@MainActor
struct SchemaDDLTransactionTests {
    private static let first = "ALTER TABLE orders ADD COLUMN a INT;"
    private static let second = "ALTER TABLE orders ADD COLUMN b INT;"

    private static func inject(
        transactions: Bool,
        transactionalDDL: Bool
    ) async throws -> (DatabaseConnection, DatabaseScope, TransactionalDDLDriver) {
        let connection = TestFixtures.makeConnection(database: "orders", type: .mysql)
        let sessionDriver = TransactionalDDLDriver(transactions: transactions, transactionalDDL: transactionalDDL)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: sessionDriver)
        )
        session.browseDatabase = "orders"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let scope = DatabaseScope(connectionId: connection.id, database: "orders", schema: nil)
        let pooled = TransactionalDDLDriver(transactions: transactions, transactionalDDL: transactionalDDL)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pooled)
        try await adapter.connect()
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)
        return (connection, scope, pooled)
    }

    private static func tearDown(_ connection: DatabaseConnection) {
        MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private static func script() -> SchemaChangeScript {
        SchemaChangeScript(
            tableName: "orders",
            statements: [first, second].map { SchemaStatement(sql: $0, description: $0, isDestructive: false) },
            operations: [],
            review: PluginSchemaChangeReview()
        )
    }

    private static func save(_ scope: DatabaseScope) async throws {
        try await DatabaseManager.shared.executeSchemaChanges(
            script(), databaseType: .mysql, scope: scope, gate: AlwaysAllowGate()
        )
    }

    private static func create(_ statements: [String], scope: DatabaseScope) async throws {
        try await DatabaseManager.shared.executeCreateTable(
            statements: statements, databaseType: .mysql, scope: scope, gate: AlwaysAllowGate()
        )
    }

    @Test("A Structure save opens no transaction where DDL is not transactional")
    func saveSkipsTheTransactionWithoutTransactionalDDL() async throws {
        let (connection, scope, pooled) = try await Self.inject(transactions: true, transactionalDDL: false)
        defer { Self.tearDown(connection) }

        try await Self.save(scope)

        #expect(pooled.executedQueries == [Self.first, Self.second])
    }

    @Test("A Structure save runs inside one transaction where DDL is transactional")
    func saveWrapsTransactionalDDL() async throws {
        let (connection, scope, pooled) = try await Self.inject(transactions: true, transactionalDDL: true)
        defer { Self.tearDown(connection) }

        try await Self.save(scope)

        #expect(pooled.executedQueries == ["BEGIN", Self.first, Self.second, "COMMIT"])
    }

    @Test("A Structure save that fails partway rolls back where DDL is transactional")
    func failedSaveRollsBack() async throws {
        let (connection, scope, pooled) = try await Self.inject(transactions: true, transactionalDDL: true)
        defer { Self.tearDown(connection) }
        pooled.failingStatement = Self.second

        await #expect(throws: DatabaseError.self) {
            try await Self.save(scope)
        }

        #expect(pooled.executedQueries == ["BEGIN", Self.first, Self.second, "ROLLBACK"])
    }

    @Test("Create Table opens no transaction where DDL is not transactional")
    func createSkipsTheTransactionWithoutTransactionalDDL() async throws {
        let (connection, scope, pooled) = try await Self.inject(transactions: true, transactionalDDL: false)
        defer { Self.tearDown(connection) }

        try await Self.create([Self.first, Self.second], scope: scope)

        #expect(pooled.executedQueries == [Self.first, Self.second])
    }

    @Test("Create Table runs its statements inside one transaction where DDL is transactional")
    func createWrapsTransactionalDDL() async throws {
        let (connection, scope, pooled) = try await Self.inject(transactions: true, transactionalDDL: true)
        defer { Self.tearDown(connection) }

        try await Self.create([Self.first, Self.second], scope: scope)

        #expect(pooled.executedQueries == ["BEGIN", Self.first, Self.second, "COMMIT"])
    }

    @Test("Create Table with a single statement opens no transaction")
    func singleStatementCreateIsNotWrapped() async throws {
        let (connection, scope, pooled) = try await Self.inject(transactions: true, transactionalDDL: true)
        defer { Self.tearDown(connection) }

        try await Self.create([Self.first], scope: scope)

        #expect(pooled.executedQueries == [Self.first])
    }

    @Test("Create Table that fails after its first statement outside a transaction reports the table as created")
    func createFailingLaterOutsideATransactionIsIncomplete() async throws {
        let (connection, scope, pooled) = try await Self.inject(transactions: true, transactionalDDL: false)
        defer { Self.tearDown(connection) }
        pooled.failingStatement = Self.second

        await #expect(throws: CreateTableIncompleteError.self) {
            try await Self.create([Self.first, Self.second], scope: scope)
        }
    }

    @Test("Create Table whose first statement fails reports the failure itself")
    func createFailingFirstIsNotIncomplete() async throws {
        let (connection, scope, pooled) = try await Self.inject(transactions: true, transactionalDDL: false)
        defer { Self.tearDown(connection) }
        pooled.failingStatement = Self.first

        await #expect(throws: DatabaseError.self) {
            try await Self.create([Self.first, Self.second], scope: scope)
        }
        #expect(pooled.executedQueries == [Self.first])
    }

    @Test("Create Table that fails inside a transaction rolls back and reports the failure itself")
    func createFailingInsideATransactionRollsBack() async throws {
        let (connection, scope, pooled) = try await Self.inject(transactions: true, transactionalDDL: true)
        defer { Self.tearDown(connection) }
        pooled.failingStatement = Self.second

        await #expect(throws: DatabaseError.self) {
            try await Self.create([Self.first, Self.second], scope: scope)
        }
        #expect(pooled.executedQueries == ["BEGIN", Self.first, Self.second, "ROLLBACK"])
    }

    @Test("The wrap needs both transactions and transactional DDL")
    func wrapRule() {
        let connection = TestFixtures.makeConnection(type: .mysql)
        for (transactions, transactionalDDL) in [(false, false), (false, true), (true, false), (true, true)] {
            let adapter = PluginDriverAdapter(
                connection: connection,
                pluginDriver: TransactionalDDLDriver(transactions: transactions, transactionalDDL: transactionalDDL)
            )
            #expect(DatabaseManager.wrapsDDLInTransaction(adapter) == (transactions && transactionalDDL))
        }
    }
}
