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
        database: String = "app"
    ) -> (connection: DatabaseConnection, driver: TransactionScriptedDriver) {
        let connection = TestFixtures.makeConnection(database: database, type: .mysql)
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

        _ = try await bridge.transactionControl(scope: scope, action: "begin")
        #expect(Self.states(connection.id) == [.open])

        _ = try await bridge.transactionControl(scope: scope, action: "rollback")
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
            holdsTransaction: { $0.container == "sales" }
        )

        let sales = entries.first { $0.container == "sales" }
        let hr = entries.first { $0.container == "hr" }
        #expect(sales?.holdsTransaction == true)
        #expect(hr?.holdsTransaction == false)
        let spoken = sales.map { WorkspaceRailCellView.voiceOverLabel(for: $0) } ?? ""
        #expect(spoken.contains("transaction open"))
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

    var state: PluginSessionTransactionState {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var statements: [String] { lock.withLock { sent } }

    var failsNextStatementAborting: Bool {
        get { lock.withLock { abortsNext } }
        set { lock.withLock { abortsNext = newValue } }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        let failure: Bool = lock.withLock {
            sent.append(query)
            if abortsNext {
                abortsNext = false
                current = .abortedTransaction
                return true
            }
            switch query.uppercased() {
            case "BEGIN": current = .inTransaction
            case "COMMIT", "ROLLBACK": current = .idle
            default: break
            }
            return false
        }
        if failure { throw TransactionScriptedFailure() }
        return .empty
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { state }
}

private struct TransactionScriptedFailure: Error {}
