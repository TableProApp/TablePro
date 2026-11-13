//
//  AppDefinitionCommitTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class DefinitionLedger: @unchecked Sendable {
    struct Failure: Error, Equatable {
        let step: String
    }

    private let lock = NSLock()
    private var current: PluginSessionTransactionState
    private var sent: [String] = []

    init(state: PluginSessionTransactionState = .idle) {
        current = state
    }

    var state: PluginSessionTransactionState {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var calls: [String] { lock.withLock { sent } }

    func record(_ call: String) {
        lock.withLock { sent.append(call) }
    }
}

struct AppDefinitionCommitTests {
    private static func run(
        _ ledger: DefinitionLedger,
        family: TransactionEngineFamily = .teradata,
        refuses: Bool = false,
        commitFails: Bool = false,
        body: () async throws -> Void
    ) async throws {
        try await AppDefinitionCommit.run(
            family: family,
            refusesOpenTransaction: refuses,
            readState: { ledger.state },
            commit: {
                // A driver's cancel handler refuses a statement sent from a cancelled task.
                try Task.checkCancellation()
                ledger.record("COMMIT")
                if commitFails { throw DefinitionLedger.Failure(step: "COMMIT") }
                ledger.state = .idle
            },
            rollback: {
                try Task.checkCancellation()
                ledger.record("ROLLBACK")
                ledger.state = .idle
            },
            body: body
        )
    }

    private static func definition(_ ledger: DefinitionLedger) {
        ledger.record("CREATE")
        ledger.state = .inTransaction
    }

    @Test("A statement that leaves the session in a transaction is committed")
    func commitsWhatTheStatementLeftOpen() async throws {
        let ledger = DefinitionLedger()

        try await Self.run(ledger) { Self.definition(ledger) }

        #expect(ledger.calls == ["CREATE", "COMMIT"])
        #expect(ledger.state == .idle)
    }

    @Test("A statement that leaves the session idle sends no commit")
    func noCommitWhenIdleAfter() async throws {
        let ledger = DefinitionLedger()

        try await Self.run(ledger) { ledger.record("CREATE") }

        #expect(ledger.calls == ["CREATE"])
    }

    @Test(
        "On the session route an open transaction refuses the statement before it runs",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction]
    )
    func refusesAnOpenTransactionOnTheSessionRoute(state: PluginSessionTransactionState) async throws {
        let ledger = DefinitionLedger(state: state)

        await #expect(throws: DefinitionInOpenTransactionRefusal()) {
            try await Self.run(ledger, refuses: true) { Self.definition(ledger) }
        }
        #expect(ledger.calls.isEmpty)
    }

    @Test("On a pooled connection a transaction left pending is no reason to refuse, and is committed")
    func pooledRouteNeverRefuses() async throws {
        let ledger = DefinitionLedger(state: .inTransaction)

        try await Self.run(ledger, refuses: false) { Self.definition(ledger) }

        #expect(ledger.calls == ["CREATE", "COMMIT"])
    }

    @Test("A failed statement on an idle session is rolled back, and its own error is thrown")
    func failedStatementOnAnIdleSessionRollsBack() async throws {
        let ledger = DefinitionLedger()

        await #expect(throws: DefinitionLedger.Failure(step: "CREATE")) {
            try await Self.run(ledger) {
                ledger.record("CREATE")
                throw DefinitionLedger.Failure(step: "CREATE")
            }
        }
        #expect(ledger.calls == ["CREATE", "ROLLBACK"])
    }

    @Test("A failed statement on a session already in a transaction leaves that transaction alone")
    func failedStatementInsideATransactionSendsNoRollback() async throws {
        let ledger = DefinitionLedger(state: .inTransaction)

        await #expect(throws: DefinitionLedger.Failure(step: "CREATE")) {
            try await Self.run(ledger) {
                ledger.record("CREATE")
                throw DefinitionLedger.Failure(step: "CREATE")
            }
        }
        #expect(ledger.calls == ["CREATE"])
    }

    @Test("A commit that fails on a session idle before the statement is rolled back")
    func failedCommitRollsBack() async throws {
        let ledger = DefinitionLedger()

        await #expect(throws: DefinitionLedger.Failure(step: "COMMIT")) {
            try await Self.run(ledger, commitFails: true) { Self.definition(ledger) }
        }
        #expect(ledger.calls == ["CREATE", "COMMIT", "ROLLBACK"])
    }

    @Test("An engine without the rule runs the statement as it is: no refusal, commit or rollback")
    func otherFamiliesPassThrough() async throws {
        let ledger = DefinitionLedger(state: .inTransaction)

        try await Self.run(ledger, family: .postgres, refuses: true) { Self.definition(ledger) }
        await #expect(throws: DefinitionLedger.Failure(step: "CREATE")) {
            try await Self.run(ledger, family: .other) { throw DefinitionLedger.Failure(step: "CREATE") }
        }

        #expect(ledger.calls == ["CREATE"])
    }

    @Test("The commit still goes out when the task is cancelled once the statement ran")
    func commitSurvivesCancellation() async throws {
        let ledger = DefinitionLedger()

        let task = Task {
            try await Self.run(ledger) {
                Self.definition(ledger)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        try await task.value

        #expect(ledger.calls == ["CREATE", "COMMIT"])
    }
}

private final class AnsiSessionDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PluginSessionTransactionState
    private var sent: [String] = []

    init(state: PluginSessionTransactionState = .idle) {
        current = state
    }

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }
    var supportsTransactions: Bool { true }

    var state: PluginSessionTransactionState {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var statements: [String] { lock.withLock { sent } }

    // ANSI: any request opens a transaction, and only COMMIT or ROLLBACK ends it.
    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock {
            sent.append(query)
            current = query == "COMMIT" || query == "ROLLBACK" ? .idle : .inTransaction
        }
        return .empty
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { state }

    func switchDatabase(to database: String) async throws {}

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        "CREATE TABLE \(definition.tableName) (id INTEGER)"
    }
}

@Suite(.serialized)
@MainActor
struct TeradataDefinitionCommitTests {
    private static let first = "ALTER TABLE orders ADD a INTEGER;"
    private static let second = "ALTER TABLE orders ADD b INTEGER;"

    private static func inject(database: String) -> (DatabaseConnection, AnsiSessionDriver) {
        let connection = TestFixtures.makeConnection(database: "orders", type: .teradata)
        let driver = AnsiSessionDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = database
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private static func injectPooled(_ connection: DatabaseConnection) async throws -> (DatabaseScope, AnsiSessionDriver) {
        let scope = DatabaseScope(connectionId: connection.id, database: "orders", schema: nil)
        let pooled = AnsiSessionDriver()
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pooled)
        try await adapter.connect()
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)
        return (scope, pooled)
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

    @Test("A Teradata Structure save commits each statement before the next")
    func structureSaveCommitsEachStatement() async throws {
        let (connection, _) = Self.inject(database: "orders")
        defer { Self.tearDown(connection) }
        let (scope, pooled) = try await Self.injectPooled(connection)

        try await DatabaseManager.shared.executeSchemaChanges(
            Self.script(), databaseType: .teradata, scope: scope, gate: AlwaysAllowGate()
        )

        #expect(pooled.statements == [Self.first, "COMMIT", Self.second, "COMMIT"])
        #expect(pooled.state == .idle)
    }

    @Test("Teradata Create Table commits each statement before the next")
    func createTableCommitsEachStatement() async throws {
        let (connection, _) = Self.inject(database: "orders")
        defer { Self.tearDown(connection) }
        let (scope, pooled) = try await Self.injectPooled(connection)

        try await DatabaseManager.shared.executeCreateTable(
            statements: [Self.first, Self.second], databaseType: .teradata, scope: scope, gate: AlwaysAllowGate()
        )

        #expect(pooled.statements == [Self.first, "COMMIT", Self.second, "COMMIT"])
    }

    @Test("A Teradata Structure save on the session driver is refused while the session holds a transaction")
    func sessionRouteSaveRefusedInsideAnOpenTransaction() async throws {
        let (connection, driver) = Self.inject(database: "")
        defer { Self.tearDown(connection) }
        driver.state = .inTransaction
        let scope = DatabaseScope(connectionId: connection.id, database: "", schema: nil)

        await #expect(throws: DefinitionInOpenTransactionRefusal()) {
            try await DatabaseManager.shared.executeSchemaChanges(
                Self.script(), databaseType: .teradata, scope: scope, gate: AlwaysAllowGate()
            )
        }
        #expect(driver.statements.isEmpty)
        #expect(driver.state == .inTransaction)
    }

    @Test("A Teradata batch import makes its new tables before it clears a reused one")
    func importCreatesBeforeItClears() async throws {
        let (connection, driver) = Self.inject(database: "orders")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "orders", schema: nil)
        var planner = NewTableImportPlanner()
        planner.recordCreated(TableScope(table: "reused", in: scope), createTableSQL: "CREATE TABLE reused (id INTEGER)")
        let definitions = ["reused", "fresh"].map {
            PluginCreateTableDefinition(tableName: $0, columns: [], primaryKeyColumns: [])
        }
        var created: [String] = []

        _ = try await RowImportTableMaker(connection: connection, gate: AlwaysAllowGate())
            .prepare(definitions, scope: scope, planner: planner) { table, _ in created.append(table.table) }

        #expect(created == ["fresh"])
        #expect(driver.statements.count == 3)
        #expect(Array(driver.statements.prefix(2)) == ["CREATE TABLE fresh (id INTEGER)", "COMMIT"])
        #expect(driver.statements.last?.hasPrefix("DELETE") == true)
    }

    @Test("Teradata startup commands are committed one by one")
    func startupCommandsAreCommitted() async throws {
        let connection = TestFixtures.makeConnection(type: .teradata)
        let driver = AnsiSessionDriver()
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        let commands = "DATABASE sales\nSET SESSION DATEFORM = ANSIDATE"
        let statements = DatabaseManager.startupStatements(from: commands, databaseType: .teradata)

        let failures = await DatabaseManager.shared.executeStartupCommands(
            commands, on: adapter, connectionName: "Test"
        )

        #expect(failures.isEmpty)
        #expect(statements.count == 2)
        #expect(driver.statements == statements.flatMap { [$0, "COMMIT"] })
        #expect(driver.state == .idle)
    }

    @Test("Startup commands on an engine without the rule send no commit")
    func startupCommandsElsewhereSendNoCommit() async {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let driver = AnsiSessionDriver()
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        let commands = "SET NAMES utf8mb4"

        _ = await DatabaseManager.shared.executeStartupCommands(commands, on: adapter, connectionName: "Test")

        #expect(driver.statements == DatabaseManager.startupStatements(from: commands, databaseType: .mysql))
    }
}
