//
//  SessionTransactionTrackerTests.swift
//  TableProTests
//
//  The bar on every tab and the connections strip mark read one record of which session connections
//  hold a transaction. Every turn on a session connection writes it, so editor runs, grid saves and
//  MCP transaction_control calls all move it, and a session that ends clears it.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Session transaction tracking", .serialized)
@MainActor
struct SessionTransactionTrackerTests {
    private static func seed(
        database: String = "app",
        type: DatabaseType = .mysql,
        commitMode: ConnectionCommitMode = .automatic
    ) -> (connection: DatabaseConnection, driver: TransactionScriptedDriver) {
        var connection = TestFixtures.makeConnection(database: database, type: type)
        connection.commitMode = commitMode
        let driver = TransactionScriptedDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = database
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private static func run(_ sql: String, on connectionId: UUID, database: String = "app") async throws {
        let scope = DatabaseScope(connectionId: connectionId, database: database, schema: nil)
        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: .sessionDriver,
            cancellation: .protectedWrite
        ) { driver in
            try await driver.execute(query: sql)
        }
    }

    // The editor's single-statement path: the hold is opened inside the same turn as the write.
    private static func runInMode(
        _ mode: ConnectionCommitMode,
        _ sql: String,
        on connectionId: UUID,
        type: DatabaseType = .postgresql
    ) async throws {
        let scope = DatabaseScope(connectionId: connectionId, database: "app", schema: nil)
        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: .sessionDriver,
            cancellation: .protectedWrite
        ) { driver in
            _ = try await ManualCommit.openIfNeeded(
                on: driver, statements: [sql], databaseType: type, grammar: type.lexicalGrammar, commitMode: mode
            )
            return try await driver.execute(query: sql)
        }
    }

    private static func scope(_ connectionId: UUID) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "app", schema: nil)
    }

    private static var tracker: SessionTransactionTracker { DatabaseManager.shared.sessionTransactions }

    private static func states(_ connectionId: UUID, in tracker: SessionTransactionTracker? = nil) -> [SessionTransactionTracker.State] {
        (tracker ?? Self.tracker).holds(for: connectionId).map { $0.state }
    }

    @Test("A turn that leaves a transaction open records it, and one that ends it clears it")
    func turnRecordsAndClears() async throws {
        let (connection, _) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await Self.run("BEGIN", on: connection.id)
        #expect(Self.states(connection.id) == [.open])

        try await Self.run("COMMIT", on: connection.id)
        #expect(Self.tracker.holds(for: connection.id).isEmpty)
    }

    @Test("A statement that fails inside the transaction shows it can only be rolled back")
    func failedStatementRecordsAbortedState() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await Self.run("BEGIN", on: connection.id)
        driver.failsNextStatementAborting = true
        await #expect(throws: (any Error).self) {
            try await Self.run("INSERT INTO missing VALUES (1)", on: connection.id)
        }

        #expect(Self.states(connection.id) == [.aborted])
    }

    @Test("MCP transaction_control moves the record like a typed statement does")
    func mcpTransactionControlMovesTheRecord() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let scope = DatabaseScope(connectionId: connection.id, database: "app", schema: nil)
        let bridge = MCPConnectionBridge()

        let operation = try await ApprovedOperationFixture.approve([], scope: scope, databaseType: .mysql, kind: .writeQuery)

        _ = try await bridge.transactionControl(operation, action: "begin")
        #expect(Self.states(connection.id) == [.open])

        _ = try await bridge.transactionControl(operation, action: "rollback")
        #expect(Self.tracker.holds(for: connection.id).isEmpty)
        #expect(driver.statements.suffix(1) == ["ROLLBACK"])
    }

    @Test("A session that ends takes its record with it")
    func lostSessionClears() async throws {
        let (connection, _) = Self.seed()
        try await Self.run("BEGIN", on: connection.id)
        #expect(!Self.tracker.holds(for: connection.id).isEmpty)

        DatabaseManager.shared.removeSession(for: connection.id)

        #expect(Self.tracker.holds(for: connection.id).isEmpty)
    }

    @Test("A reconnect onto a new driver clears the old driver's record")
    func replacedDriverClears() async throws {
        let (connection, _) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)

        DatabaseManager.shared.updateSession(connection.id) { session in
            session.driver = PluginDriverAdapter(connection: connection, pluginDriver: TransactionScriptedDriver())
        }

        #expect(Self.tracker.holds(for: connection.id).isEmpty)
    }

    @Test("Commit ends the transaction on the connection that holds it")
    func commitEndsTheHeldTransaction() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let hold = try #require(Self.tracker.holds(for: connection.id).first)

        try await DatabaseManager.shared.endTransaction(hold, committing: true)

        #expect(driver.statements.suffix(1) == ["COMMIT"])
        #expect(Self.tracker.holds(for: connection.id).isEmpty)
    }

    @Test("Work that ran after the hold was read refuses the action and sends nothing")
    func otherWorkRefusesTheAction() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let hold = try #require(Self.tracker.holds(for: connection.id).first)
        try await Self.run("INSERT INTO t VALUES (1)", on: connection.id)
        let sent = driver.statements.count

        await #expect(throws: SessionTransactionActionError.transactionChanged) {
            try await DatabaseManager.shared.endTransaction(hold, committing: false)
        }
        #expect(driver.statements.count == sent)
    }

    @Test("Commit on a transaction that can no longer commit sends nothing")
    func abortedCommitSendsNothing() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let hold = try #require(Self.tracker.holds(for: connection.id).first)
        driver.state = .abortedTransaction
        let sent = driver.statements.count

        await #expect(throws: SessionTransactionActionError.cannotCommit) {
            try await DatabaseManager.shared.endTransaction(hold, committing: true)
        }
        #expect(driver.statements.count == sent)
    }

    @Test("A lane holds a transaction for its own database's entry only; one driver holds it for every entry")
    func stripMarkFollowsTheLane() {
        let laneDriver = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: TransactionScriptedDriver())
        let tracker = SessionTransactionTracker { _, _ in true }
        let connectionId = UUID()

        tracker.record(.inTransaction, on: laneDriver, for: .init(connectionId: connectionId, lane: "sales"))
        #expect(tracker.holdsTransaction(connectionId: connectionId, container: "sales"))
        #expect(!tracker.holdsTransaction(connectionId: connectionId, container: "hr"))

        let other = UUID()
        tracker.record(.inTransaction, on: laneDriver, for: .init(connectionId: other, lane: nil))
        #expect(tracker.holdsTransaction(connectionId: other, container: "anything"))
    }

    @Test("An engine that cannot say keeps the same driver's earlier answer and drops another driver's")
    func unknownKeepsOnlyTheSameDriver() {
        let first = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: TransactionScriptedDriver())
        let second = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: TransactionScriptedDriver())
        let tracker = SessionTransactionTracker { _, _ in true }
        let key = SessionTransactionTracker.Key(connectionId: UUID(), lane: nil)

        tracker.record(.inTransaction, on: first, for: key)
        tracker.record(.unknown, on: first, for: key)
        #expect(Self.states(key.connectionId, in: tracker) == [.open])

        tracker.record(.unknown, on: second, for: key)
        #expect(tracker.holds(for: key.connectionId).isEmpty)
    }

    @Test("A late answer from a retired driver leaves the replacement's hold alone")
    func retiredDriverCannotClearTheReplacement() {
        let retired = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: TransactionScriptedDriver())
        let replacement = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: TransactionScriptedDriver())
        let tracker = SessionTransactionTracker { _, driver in driver === replacement }
        let key = SessionTransactionTracker.Key(connectionId: UUID(), lane: nil)
        tracker.record(.inTransaction, on: replacement, for: key)
        let before = tracker.holds(for: key.connectionId)

        tracker.record(.idle, on: retired, for: key)

        #expect(tracker.holds(for: key.connectionId) == before)
        #expect(Self.states(key.connectionId, in: tracker) == [.open])
    }

    @Test("The strip marks the entries the record names")
    func railEntriesCarryTheMark() {
        let connection = TestFixtures.makeConnection(database: "sales", type: .mysql)
        let entries = WorkspaceRailStore.resolveEntries(
            openConnectionIds: [connection.id],
            sessions: [:],
            storedConnections: [connection.id: connection],
            containerTarget: { _ in .database },
            tabs: { _ in [] },
            openedContainers: { _ in ["sales", "hr"] },
            storedOrder: [],
            transaction: { $0.container == "sales" ? .open : nil }
        )

        let sales = entries.first { $0.container == "sales" }
        let hr = entries.first { $0.container == "hr" }
        #expect(sales?.holdsTransaction == true)
        #expect(hr?.holdsTransaction == false)
        let spoken = sales.map { WorkspaceRailCellView.voiceOverLabel(for: $0) } ?? ""
        #expect(spoken.contains("transaction open"))
    }

    @Test("An aborted hold on any lane an entry covers wins over an open one")
    func abortedHoldWinsForTheEntry() {
        let tracker = SessionTransactionTracker { _, _ in true }
        let connectionId = UUID()
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: TransactionScriptedDriver())
        let otherDriver = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: TransactionScriptedDriver())
        tracker.record(.inTransaction, on: driver, for: .init(connectionId: connectionId, lane: nil))
        tracker.record(.abortedTransaction, on: otherDriver, for: .init(connectionId: connectionId, lane: "sales"))

        #expect(tracker.transactionState(connectionId: connectionId, container: "sales") == .aborted)
        #expect(tracker.transactionState(connectionId: connectionId, container: "hr") == .open)
        #expect(tracker.transactionState(connectionId: UUID(), container: "sales") == nil)
        #expect(tracker.holdsTransaction(connectionId: connectionId, container: "hr"))
    }

    @Test("In Manual Commit an UPDATE sends BEGIN first and leaves the transaction open")
    func manualCommitOpensTheHold() async throws {
        let (connection, driver) = Self.seed(type: .postgresql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await Self.runInMode(.manual, "UPDATE t SET a = 1", on: connection.id)

        #expect(driver.statements == ["BEGIN", "UPDATE t SET a = 1"])
        #expect(Self.states(connection.id) == [.open])
    }

    @Test("Manual Commit sends no BEGIN for a read, nor a second one for a later write")
    func manualCommitBeginsOnce() async throws {
        let (connection, driver) = Self.seed(type: .postgresql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await Self.runInMode(.manual, "SELECT * FROM t", on: connection.id)
        #expect(driver.statements == ["SELECT * FROM t"])
        #expect(Self.tracker.holds(for: connection.id).isEmpty)

        try await Self.runInMode(.manual, "UPDATE t SET a = 1", on: connection.id)
        try await Self.runInMode(.manual, "UPDATE t SET a = 2", on: connection.id)
        #expect(driver.statements == ["SELECT * FROM t", "BEGIN", "UPDATE t SET a = 1", "UPDATE t SET a = 2"])
    }

    @Test("Automatic commit sends no BEGIN")
    func automaticCommitOpensNothing() async throws {
        let (connection, driver) = Self.seed(type: .postgresql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await Self.runInMode(.automatic, "UPDATE t SET a = 1", on: connection.id)

        #expect(driver.statements == ["UPDATE t SET a = 1"])
        #expect(Self.tracker.holds(for: connection.id).isEmpty)
    }

    @Test(
        "A session that cannot report, or holds only a lock, refuses the write and sends nothing",
        arguments: [PluginSessionTransactionState.unknown, .holdsSessionLocks]
    )
    func unholdableSessionRefuses(state: PluginSessionTransactionState) async throws {
        let (connection, driver) = Self.seed(type: .postgresql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        driver.state = state

        await #expect(throws: ManualCommitRefusal()) {
            try await Self.runInMode(.manual, "UPDATE t SET a = 1", on: connection.id)
        }
        #expect(driver.statements.isEmpty)
    }

    @Test("A driver that only answers that it cannot say is reported, and one earlier answer outlasts a later unknown")
    func readerThatCannotReportIsRemembered() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        driver.state = .unknown
        try await Self.run("SELECT 1", on: connection.id)
        #expect(Self.tracker.cannotReportState(connectionId: connection.id, container: "app"))

        driver.state = .idle
        try await Self.run("SELECT 1", on: connection.id)
        driver.state = .unknown
        try await Self.run("SELECT 1", on: connection.id)
        #expect(!Self.tracker.cannotReportState(connectionId: connection.id, container: "app"))
    }

    @Test("A table read leaves the hold's revision alone, and a write lease that owns no session state moves it")
    func readOnlyTurnKeepsTheRevision() async throws {
        let (connection, _) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let hold = try #require(Self.tracker.holds(for: connection.id).first)

        _ = try await DatabaseManager.shared.withTableReadDriver(scope: Self.scope(connection.id), cancellation: .untracked) { driver in
            try await driver.execute(query: "SELECT * FROM t")
        }
        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: Self.scope(connection.id), route: .sessionDriver, cancellation: .untracked,
            ownsSessionState: false, readsOnly: true
        ) { driver in
            try await driver.execute(query: "SELECT 1")
        }
        #expect(Self.tracker.isCurrent(hold))

        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: Self.scope(connection.id), route: .sessionDriver, cancellation: .untracked, ownsSessionState: false
        ) { driver in
            try await driver.execute(query: "INSERT INTO t VALUES (1)")
        }
        #expect(!Self.tracker.isCurrent(hold))
    }

    @Test("A read-only turn that finds the transaction failed still moves the hold")
    func readOnlyTurnStillReportsAFailure() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let hold = try #require(Self.tracker.holds(for: connection.id).first)
        driver.failsNextStatementAborting = true

        await #expect(throws: (any Error).self) {
            try await DatabaseManager.shared.withTableReadDriver(scope: Self.scope(connection.id), cancellation: .untracked) { driver in
                try await driver.execute(query: "SELECT * FROM missing")
            }
        }

        #expect(!Self.tracker.isCurrent(hold))
        #expect(Self.states(connection.id) == [.aborted])
    }

    @Test("MCP begin is refused over a transaction already open and sends nothing")
    func mcpBeginRefusedOverAnOpenTransaction() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let sent = driver.statements.count
        let operation = try await ApprovedOperationFixture.approve(
            [], scope: Self.scope(connection.id), databaseType: .mysql, kind: .writeQuery
        )

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await MCPConnectionBridge().transactionControl(operation, action: "begin")
        }
        #expect(driver.statements.count == sent)
    }

    @Test("Manual Commit refuses every MCP transaction action", arguments: ["begin", "commit", "rollback"])
    func mcpTransactionControlRefusedInManualCommit(action: String) async throws {
        let (connection, driver) = Self.seed(type: .postgresql, commitMode: .manual)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let operation = try await ApprovedOperationFixture.approve(
            [], scope: Self.scope(connection.id), databaseType: .postgresql, kind: .writeQuery
        )

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await MCPConnectionBridge().transactionControl(operation, action: action)
        }
        #expect(driver.statements.isEmpty)
    }

    @Test("An agent's write in Manual Commit is held, and its reply says the change is pending")
    func mcpWriteIsHeldAndSaysSo() async throws {
        let (connection, driver) = Self.seed(type: .postgresql, commitMode: .manual)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let outcome = try await DatabaseAccessBridge().runStatement(
            scope: Self.scope(connection.id), query: "UPDATE t SET a = 1", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        let begin = try #require(driver.statements.firstIndex(of: "BEGIN"))
        let update = try #require(driver.statements.firstIndex(of: "UPDATE t SET a = 1"))
        #expect(begin < update)
        #expect(!driver.statements.contains("COMMIT"))
        #expect(outcome.result.statusMessage?.contains(ManualCommit.pendingNotice) == true)
        #expect(Self.states(connection.id) == [.open])
    }

    @Test("An agent's insert_rows in Manual Commit is held: BEGIN first, and no COMMIT")
    func mcpInsertRowsIsHeld() async throws {
        let (connection, driver) = Self.seed(type: .postgresql, commitMode: .manual)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let rows = ["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (2)"]
        let operation = try await ApprovedOperationFixture.approve(
            rows.map { OperationStatement(sql: $0) }, scope: Self.scope(connection.id), databaseType: .postgresql,
            kind: .writeQuery
        )

        let inserted = try await DatabaseAccessBridge().runInserts(operation)

        let begin = try #require(driver.statements.firstIndex(of: "BEGIN"))
        let first = try #require(driver.statements.firstIndex(of: rows[0]))
        #expect(begin < first)
        #expect(driver.statements.contains(rows[1]))
        #expect(!driver.statements.contains("COMMIT"))
        #expect(Self.states(connection.id) == [.open])
        #expect(inserted.notice == ManualCommit.pendingNotice)
    }

    @Test("An insert_rows that leaves a Teradata ANSI transaction open says so")
    func mcpInsertRowsThatOpenATransactionSaySo() async throws {
        let (connection, driver) = Self.seed(type: .teradata)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        driver.writesOpenATransaction = true
        let operation = try await ApprovedOperationFixture.approve(
            [OperationStatement(sql: "INSERT INTO t VALUES (1)")], scope: Self.scope(connection.id), databaseType: .teradata,
            kind: .writeQuery
        )

        let inserted = try await DatabaseAccessBridge().runInserts(operation)

        #expect(inserted.notice == ManualCommit.statementOpenedNotice)
    }

    @Test("An insert_rows of several rows joining an open SQLite transaction is taken back whole when a row fails")
    func mcpInsertRowsJoiningATransactionIsOneUnit() async throws {
        let (connection, driver) = Self.seed(type: .sqlite, commitMode: .manual)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let rows = ["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (2)"]
        driver.failingStatement = rows[1]
        let operation = try await ApprovedOperationFixture.approve(
            rows.map { OperationStatement(sql: $0) }, scope: Self.scope(connection.id), databaseType: .sqlite,
            kind: .writeQuery
        )

        await #expect(throws: (any Error).self) {
            _ = try await DatabaseAccessBridge().runInserts(operation)
        }

        #expect(driver.statements.suffix(4) == [
            AgentTransactionGuard.savepointStatement, rows[0], rows[1], AgentTransactionGuard.rollbackStatement,
        ])
        #expect(!driver.statements.contains("COMMIT"))
    }

    @Test("An insert_rows joining an open SQL Server transaction takes SAVE TRANSACTION, which has no release")
    func mcpInsertRowsOnSQLServerTakesItsSavepoint() async throws {
        let (connection, driver) = Self.seed(type: .mssql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let rows = ["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (2)"]
        let operation = try await ApprovedOperationFixture.approve(
            rows.map { OperationStatement(sql: $0) }, scope: Self.scope(connection.id), databaseType: .mssql,
            kind: .writeQuery
        )

        _ = try await DatabaseAccessBridge().runInserts(operation)

        #expect(driver.statements.suffix(3) == ["SAVE TRANSACTION tablepro_agent", rows[0], rows[1]])
    }

    @Test("An agent's COMMIT, ROLLBACK or BEGIN in Manual Commit is refused and sends nothing", arguments: ["COMMIT", "ROLLBACK", "BEGIN"])
    func mcpTransactionStatementRefusedInManualCommit(sql: String) async throws {
        let (connection, driver) = Self.seed(type: .postgresql, commitMode: .manual)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.runInMode(.manual, "UPDATE t SET a = 1", on: connection.id)
        let sent = driver.statements.count

        let error = await #expect(throws: (any Error).self) {
            _ = try await DatabaseAccessBridge().runStatement(
                scope: Self.scope(connection.id), query: sql, maxRows: 10, timeoutSeconds: 30, cancellation: nil
            )
        }
        #expect(error?.localizedDescription == ManualCommit.transactionControlRefusalMessage)
        #expect(driver.statements.count == sent)
        #expect(Self.states(connection.id) == [.open])
    }

    @Test(
        "With Manual Commit holding a transaction, an agent statement that can end it unseen is refused",
        arguments: [
            (DatabaseType.mssql, "UPDATE t SET a = 1 COMMIT"),
            (DatabaseType.mssql, "EXEC dbo.p"),
            (DatabaseType.postgresql, "CALL p()"),
        ]
    )
    func mcpUnseenTransactionControlRefused(type: DatabaseType, sql: String) async throws {
        let (connection, driver) = Self.seed(type: type, commitMode: .manual)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let sent = driver.statements.count

        let error = await #expect(throws: (any Error).self) {
            _ = try await DatabaseAccessBridge().runStatement(
                scope: Self.scope(connection.id), query: sql, maxRows: 10, timeoutSeconds: 30, cancellation: nil
            )
        }
        #expect(error?.localizedDescription == ManualCommit.transactionControlRefusalMessage)
        #expect(driver.statements.count == sent)
        #expect(Self.states(connection.id) == [.open])
    }

    // Its own COMMIT would end the hold this call opens for its write.
    @Test(
        "On an idle Manual Commit session, an agent write that can end a transaction unseen is refused",
        arguments: [
            (DatabaseType.mssql, "UPDATE t SET a = 1 COMMIT"),
            (DatabaseType.postgresql, "CALL p()"),
        ]
    )
    func mcpUnseenWriteRefusedOnAnIdleSession(type: DatabaseType, sql: String) async throws {
        let (connection, driver) = Self.seed(type: type, commitMode: .manual)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let error = await #expect(throws: (any Error).self) {
            _ = try await DatabaseAccessBridge().runStatement(
                scope: Self.scope(connection.id), query: sql, maxRows: 10, timeoutSeconds: 30, cancellation: nil
            )
        }
        #expect(error?.localizedDescription == ManualCommit.transactionControlRefusalMessage)
        #expect(driver.statements.isEmpty)
    }

    @Test("An agent statement that ended the open transaction says so in its reply")
    func mcpReplySaysTheTransactionEnded() async throws {
        let (connection, _) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)

        let outcome = try await DatabaseAccessBridge().runStatement(
            scope: Self.scope(connection.id), query: "COMMIT", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        #expect(outcome.result.statusMessage?.contains(ManualCommit.transactionEndedNotice) == true)
        #expect(Self.tracker.holds(for: connection.id).isEmpty)
    }

    @Test("An agent's BEGIN over a transaction already open is refused, whatever the commit mode")
    func mcpBeginStatementRefusedOverAnOpenTransaction() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let sent = driver.statements.count

        let error = await #expect(throws: (any Error).self) {
            _ = try await DatabaseAccessBridge().runStatement(
                scope: Self.scope(connection.id), query: "START TRANSACTION", maxRows: 10, timeoutSeconds: 30,
                cancellation: nil
            )
        }
        #expect(error?.localizedDescription == ManualCommit.openTransactionRefusalMessage)
        #expect(driver.statements.count == sent)
    }

    @Test("An agent statement over an open PostgreSQL transaction runs inside a savepoint it releases")
    func agentStatementTakesASavepoint() async throws {
        let (connection, driver) = Self.seed(type: .postgresql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)

        _ = try await DatabaseAccessBridge().runStatement(
            scope: Self.scope(connection.id), query: "UPDATE t SET a = 1", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        #expect(driver.statements.suffix(3) == [
            AgentTransactionGuard.savepointStatement, "UPDATE t SET a = 1", AgentTransactionGuard.releaseStatement,
        ])
    }

    @Test("An agent statement that fails inside an open PostgreSQL transaction is rolled back to its savepoint")
    func failedAgentStatementRollsBackToItsSavepoint() async throws {
        let (connection, driver) = Self.seed(type: .postgresql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        driver.failingStatement = "UPDATE t SET a = 1 / 0"

        await #expect(throws: (any Error).self) {
            _ = try await DatabaseAccessBridge().runStatement(
                scope: Self.scope(connection.id), query: "UPDATE t SET a = 1 / 0", maxRows: 10, timeoutSeconds: 30,
                cancellation: nil
            )
        }

        #expect(driver.statements.suffix(3) == [
            AgentTransactionGuard.savepointStatement, "UPDATE t SET a = 1 / 0", AgentTransactionGuard.rollbackStatement,
        ])
    }

    @Test("An agent statement over an open transaction with no savepoint is refused, since a failure would abort it",
          arguments: [DatabaseType.duckdb, .teradata])
    func agentStatementRefusedWithoutSavepoints(type: DatabaseType) async throws {
        let (connection, driver) = Self.seed(type: type)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let sent = driver.statements.count

        let error = await #expect(throws: (any Error).self) {
            _ = try await DatabaseAccessBridge().runStatement(
                scope: Self.scope(connection.id), query: "SELECT 1", maxRows: 10, timeoutSeconds: 30, cancellation: nil
            )
        }
        #expect(error?.localizedDescription == AbortingTransactionRefusal().errorDescription)
        #expect(driver.statements.count == sent)
    }

    @Test("An agent's write that leaves a Teradata ANSI transaction open says so, and the next statement is refused")
    func agentWriteThatOpensATransactionSaysSo() async throws {
        let (connection, driver) = Self.seed(type: .teradata)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        driver.writesOpenATransaction = true

        let outcome = try await DatabaseAccessBridge().runStatement(
            scope: Self.scope(connection.id), query: "UPDATE t SET a = 1", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )
        #expect(outcome.result.statusMessage?.contains(ManualCommit.statementOpenedNotice) == true)

        let error = await #expect(throws: (any Error).self) {
            _ = try await DatabaseAccessBridge().runStatement(
                scope: Self.scope(connection.id), query: "SELECT 1", maxRows: 10, timeoutSeconds: 30, cancellation: nil
            )
        }
        #expect(error?.localizedDescription == AbortingTransactionRefusal().errorDescription)
    }

    @Test("An agent's own BEGIN on PostgreSQL gets no notice that later statements are refused")
    func agentBeginIsNotTakenForAHeldWrite() async throws {
        let (connection, _) = Self.seed(type: .postgresql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let outcome = try await DatabaseAccessBridge().runStatement(
            scope: Self.scope(connection.id), query: "BEGIN", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        #expect(outcome.result.statusMessage?.contains(ManualCommit.statementOpenedNotice) != true)
    }

    @Test("Turning Manual Commit on writes the session and the connection it was opened from")
    func menuToggleWritesTheSession() {
        let (connection, _) = Self.seed(type: .postgresql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.setCommitMode(.manual, for: connection.id)

        #expect(DatabaseManager.shared.commitMode(for: connection.id) == .manual)
        #expect(DatabaseManager.shared.session(for: connection.id)?.connection.commitMode == .manual)
    }

    @Test("A Manual Commit stored on a MySQL connection runs as automatic: an agent's write sends no BEGIN")
    func storedManualCommitOnMySQLRunsAutomatic() async throws {
        let (connection, driver) = Self.seed(type: .mysql, commitMode: .manual)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        #expect(DatabaseManager.shared.session(for: connection.id)?.connection.commitMode == .manual)
        #expect(DatabaseManager.shared.commitMode(for: connection.id) == .automatic)

        let outcome = try await DatabaseAccessBridge().runStatement(
            scope: Self.scope(connection.id), query: "UPDATE t SET a = 1", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        #expect(driver.statements.contains("UPDATE t SET a = 1"))
        #expect(!driver.statements.contains("BEGIN"))
        #expect(outcome.result.statusMessage?.contains(ManualCommit.pendingNotice) != true)
        #expect(Self.tracker.holds(for: connection.id).isEmpty)
    }

    @Test("Read-only hides Commit, an aborted transaction offers only Roll Back")
    func barContent() {
        let open = ConnectionTransactionBarContent(
            isAborted: false,
            connectionName: "Prod",
            database: "sales",
            safeModeLevel: .silent
        )
        #expect(open.title == "Transaction Open")
        #expect(open.subtitle == "sales")
        #expect(open.offersCommit)
        #expect(open.accessibilityLabel == "Transaction open on sales, Prod")

        let readOnly = ConnectionTransactionBarContent(
            isAborted: false,
            connectionName: "Prod",
            database: nil,
            safeModeLevel: .readOnly
        )
        #expect(!readOnly.offersCommit)
        #expect(readOnly.subtitle == "Prod")

        let aborted = ConnectionTransactionBarContent(
            isAborted: true,
            connectionName: "Prod",
            database: "",
            safeModeLevel: .silent
        )
        #expect(!aborted.offersCommit)
        #expect(aborted.title == "Transaction Failed")
        #expect(aborted.accessibilityLabel == "Transaction failed on Prod. Roll it back to continue.")
    }
}

/// Answers its session state from the statements it saw, like a server that reports the flag in
/// every reply.
private final class TransactionScriptedDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PluginSessionTransactionState = .idle
    private var sent: [String] = []
    private var abortsNext = false
    private var opensOnWrite = false

    // As a Teradata ANSI session does: a change opens a transaction only COMMIT ends.
    var writesOpenATransaction: Bool {
        get { lock.withLock { opensOnWrite } }
        set { lock.withLock { opensOnWrite = newValue } }
    }

    var state: PluginSessionTransactionState {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var statements: [String] { lock.withLock { sent } }

    var failsNextStatementAborting: Bool {
        get { lock.withLock { abortsNext } }
        set { lock.withLock { abortsNext = newValue } }
    }

    private var failing: String?

    // That statement fails and aborts the transaction, the way PostgreSQL answers a division by zero.
    var failingStatement: String? {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        let failure: Bool = lock.withLock {
            sent.append(query)
            if abortsNext || query == failing {
                abortsNext = false
                current = .abortedTransaction
                return true
            }
            switch query.uppercased() {
            case "BEGIN": current = .inTransaction
            case "COMMIT", "ROLLBACK": current = .idle
            case let write where opensOnWrite && (write.hasPrefix("UPDATE") || write.hasPrefix("INSERT")):
                current = .inTransaction
            default: break
            }
            return false
        }
        if failure { throw TransactionScriptedFailure() }
        return .empty
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { state }

    // A turn pins a MySQL scope to its database first, as a real session does.
    func switchDatabase(to database: String) async throws {}
}

private struct TransactionScriptedFailure: Error {}
