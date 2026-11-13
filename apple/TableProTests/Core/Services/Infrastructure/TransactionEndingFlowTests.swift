//
//  TransactionEndingFlowTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@Suite(.serialized)
@MainActor
struct TransactionEndingFlowTests {
    private static func seed(
        name: String = "Prod",
        safeModeLevel: SafeModeLevel = .silent
    ) -> (connection: DatabaseConnection, driver: EndingScriptedDriver) {
        var connection = TestFixtures.makeConnection(name: name, database: "app", type: .mysql)
        connection.safeModeLevel = safeModeLevel
        let driver = EndingScriptedDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = "app"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private static func run(_ sql: String, on connectionId: UUID) async throws {
        let scope = DatabaseScope(connectionId: connectionId, database: "app", schema: nil)
        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: .sessionDriver,
            cancellation: .protectedWrite
        ) { driver in
            try await driver.execute(query: sql)
        }
    }

    private static func holds(_ connectionId: UUID) -> [SessionTransactionTracker.Hold] {
        DatabaseManager.shared.sessionTransactions.holds(for: connectionId)
    }

    // The flow as a close or disconnect runs it, with the alert answered by the test and the gate injected.
    private static func resolve(
        _ connectionId: UUID,
        answers: [AlertHelper.TransactionEndAnswer],
        asked: inout [TransactionEndPrompt],
        failures: inout [String],
        gate: any ExecutionGate = AlwaysAllowGate(),
        commit: (@MainActor ([SessionTransactionTracker.Hold]) async throws -> Bool)? = nil
    ) async -> TransactionEndingFlow.Outcome {
        var remaining = answers
        var seen: [TransactionEndPrompt] = []
        var reported: [String] = []
        let outcome = await TransactionEndingFlow.resolve(
            connectionId: connectionId,
            action: .disconnect(name: "Prod"),
            window: { nil },
            ask: { prompt, _ in
                seen.append(prompt)
                return remaining.isEmpty ? .cancel : remaining.removeFirst()
            },
            commit: { holds in
                if let commit { return try await commit(holds) }
                return try await ConnectionTransactionActions.commitBeforeEnding(holds, gate: gate)
            },
            reportFailure: { message, _ in reported.append(message) }
        )
        asked = seen
        failures = reported
        return outcome
    }

    @Test("Nothing open asks nothing and lets the close go ahead")
    func nothingOpenAsksNothing() async throws {
        let (connection, _) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []

        let outcome = await Self.resolve(connection.id, answers: [.commit], asked: &asked, failures: &failures)

        #expect(outcome == .nothingOpen)
        #expect(asked.isEmpty)
    }

    @Test("Commit commits the open transaction, then the close goes ahead")
    func commitThenProceed() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []

        let outcome = await Self.resolve(connection.id, answers: [.commit], asked: &asked, failures: &failures)

        #expect(outcome == .ended)
        #expect(asked.count == 1)
        #expect(asked.first?.offersCommit == true)
        #expect(driver.statements.filter { $0 == "COMMIT" }.count == 1)
        #expect(driver.statements.last == "COMMIT")
        #expect(Self.holds(connection.id).isEmpty)
        #expect(failures.isEmpty)
    }

    // The disconnect that follows ends the session, and the server rolls back what it held.
    @Test("Roll Back sends nothing and asks no more")
    func rollBackProceedsWithoutReasking() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []

        let outcome = await Self.resolve(connection.id, answers: [.rollBack, .commit], asked: &asked, failures: &failures)

        #expect(outcome == .ended)
        #expect(asked.count == 1)
        #expect(!driver.statements.contains("COMMIT"))
        #expect(!driver.statements.contains("ROLLBACK"))
        #expect(Self.holds(connection.id).count == 1)
    }

    @Test("Cancel keeps the transaction and the connection")
    func cancelKeepsEverything() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []

        let outcome = await Self.resolve(connection.id, answers: [.cancel], asked: &asked, failures: &failures)

        #expect(outcome == .cancelled)
        #expect(!driver.statements.contains("COMMIT"))
        #expect(!driver.statements.contains("ROLLBACK"))
        #expect(Self.holds(connection.id).count == 1)
    }

    @Test("Cancelling the Safe Mode question commits nothing and keeps the connection")
    func gateCancelKeepsTheConnection() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []

        let outcome = await Self.resolve(
            connection.id, answers: [.commit], asked: &asked, failures: &failures, gate: AlwaysDenyGate.cancelling
        )

        #expect(outcome == .cancelled)
        #expect(!driver.statements.contains("COMMIT"))
        #expect(!driver.statements.contains("ROLLBACK"))
        #expect(failures.isEmpty)
    }

    // A commit that failed and a close that went ahead anyway would be a rollback nobody chose.
    @Test("A failed commit shows the error and keeps the connection")
    func failedCommitKeepsTheConnection() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []

        let outcome = await Self.resolve(connection.id, answers: [.commit], asked: &asked, failures: &failures) { _ in
            throw SessionTransactionActionError.cannotCommit
        }

        #expect(outcome == .cancelled)
        #expect(failures == [SessionTransactionActionError.cannotCommit.localizedDescription])
        #expect(!driver.statements.contains("COMMIT"))
        #expect(!driver.statements.contains("ROLLBACK"))
        #expect(Self.holds(connection.id).count == 1)
    }

    // Read-Only is the strictest level, so no managed floor on the test Mac can change this answer.
    @Test("The close prompt, the bar and the menu all withhold Commit at the gate's Read-Only level")
    func readOnlyWithholdsCommitEverywhere() async throws {
        let (connection, _) = Self.seed(safeModeLevel: .readOnly)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let hold = try #require(Self.holds(connection.id).first)
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []

        let outcome = await Self.resolve(connection.id, answers: [.cancel], asked: &asked, failures: &failures)

        #expect(outcome == .cancelled)
        #expect(asked.first?.commitBlock == .readOnly)
        #expect(!ConnectionTransactionActions.offersCommit(hold))
        let bar = ConnectionTransactionBarContent(
            isAborted: false,
            connectionName: "Prod",
            database: "app",
            effectiveSafeModeLevel: ExecutionGateProvider.effectiveSafeModeLevel(for: connection.id)
        )
        #expect(!bar.offersCommit)
    }

    @Test("A Read-Only refusal of the commit shows the reason and keeps the connection")
    func policyDenialKeepsTheConnection() async throws {
        let (connection, _) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []

        let outcome = await Self.resolve(
            connection.id, answers: [.commit], asked: &asked, failures: &failures, gate: AlwaysDenyGate()
        )

        #expect(outcome == .cancelled)
        #expect(failures == ["Read-Only connection"])
    }

    // A nested Teradata BT survives one END TRANSACTION; closing after it would roll back what the user committed.
    @Test("A transaction still open after Commit is asked about again")
    func stillOpenAfterCommitAsksAgain() async throws {
        let (connection, _) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []

        let outcome = await Self.resolve(
            connection.id, answers: [.commit, .rollBack], asked: &asked, failures: &failures
        ) { _ in true }

        #expect(outcome == .ended)
        #expect(asked.count == 2)
    }

    @Test("A transaction a second Commit ends lets the close go ahead")
    func secondCommitEndsIt() async throws {
        let (connection, driver) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        var asked: [TransactionEndPrompt] = []
        var failures: [String] = []
        var commits = 0

        let outcome = await Self.resolve(
            connection.id, answers: [.commit, .commit], asked: &asked, failures: &failures
        ) { holds in
            commits += 1
            guard commits > 1 else { return true }
            return try await ConnectionTransactionActions.commitBeforeEnding(holds, gate: AlwaysAllowGate())
        }

        #expect(outcome == .ended)
        #expect(asked.count == 2)
        #expect(driver.statements.filter { $0 == "COMMIT" }.count == 1)
        #expect(driver.statements.last == "COMMIT")
    }

    private static func entry(_ name: String, on connectionId: UUID) -> TransactionEndingFlow.Entry {
        TransactionEndingFlow.Entry(
            name: name,
            hold: SessionTransactionTracker.Hold(key: .init(connectionId: connectionId, lane: name), state: .open, revision: 1)
        )
    }

    @Test("A database that starts holding one after Roll Back is asked about, alone")
    func newDatabaseAfterRollBackAsksAgain() async {
        let id = UUID()
        let app = Self.entry("app", on: id)
        let logs = Self.entry("logs", on: id)
        var reads: [[TransactionEndingFlow.Entry]] = [[app], [app, logs], [app, logs]]
        var listed: [[String]] = []

        let outcome = await TransactionEndingFlow.run(
            read: { reads.isEmpty ? [] : reads.removeFirst() },
            prompt: { entries in
                if !entries.isEmpty { listed.append(entries.map { $0.name }) }
                return TransactionEndPrompt.make(
                    action: .closeConnection(name: "Prod"),
                    names: entries.map { $0.name },
                    holds: entries.compactMap { $0.hold },
                    effectiveLevel: { _ in .silent },
                    busy: { _ in false }
                )
            },
            ask: { _ in .rollBack },
            commit: { _ in
                Issue.record("Roll Back commits nothing")
                return true
            },
            reportFailure: { _ in }
        )

        #expect(outcome == .ended)
        #expect(listed == [["app"], ["logs"]])
    }

    @Test("Commit goes through only the holds the question listed")
    func commitTakesTheListedHolds() async {
        let app = Self.entry("app", on: UUID())
        var reads: [[TransactionEndingFlow.Entry]] = [[app], []]
        var committed: [[SessionTransactionTracker.Hold]] = []

        let outcome = await TransactionEndingFlow.run(
            read: { reads.isEmpty ? [] : reads.removeFirst() },
            prompt: { entries in
                TransactionEndPrompt.make(
                    action: .closeConnection(name: "Prod"),
                    names: entries.map { $0.name },
                    holds: entries.compactMap { $0.hold },
                    effectiveLevel: { _ in .silent },
                    busy: { _ in false }
                )
            },
            ask: { _ in .commit },
            commit: { holds in
                committed.append(holds)
                return true
            },
            reportFailure: { _ in }
        )

        #expect(outcome == .ended)
        #expect(committed.count == 1)
        #expect(committed.first?.map { $0.key.lane } == ["app"])
    }

    @Test("Commit asks the gate once per connection before anything is sent")
    func commitAuthorizesOncePerConnection() async throws {
        let (first, _) = Self.seed(name: "First")
        let (second, _) = Self.seed(name: "Second")
        defer {
            DatabaseManager.shared.removeSession(for: first.id)
            DatabaseManager.shared.removeSession(for: second.id)
        }
        let gate = RequestRecordingGate(allows: true)
        // Never recorded by the tracker, so the first one refused proves every question came before it.
        let holds = [
            SessionTransactionTracker.Hold(key: .init(connectionId: first.id, lane: "app"), state: .open, revision: 9),
            SessionTransactionTracker.Hold(key: .init(connectionId: first.id, lane: "logs"), state: .open, revision: 9),
            SessionTransactionTracker.Hold(key: .init(connectionId: second.id, lane: nil), state: .open, revision: 9),
        ]

        await #expect(throws: SessionTransactionActionError.transactionChanged) {
            _ = try await ConnectionTransactionActions.commitBeforeEnding(holds, gate: gate)
        }
        let requests = await gate.requests
        #expect(requests.map { $0.connectionId } == [first.id, second.id])
        #expect(requests.allSatisfy { $0.sql == "COMMIT" })
    }

    // A commit would wait behind the running turn, so the prompt offers Roll Back only while one runs.
    @Test("A turn running on the hold's connection makes its lane busy")
    func turnMakesTheLaneBusy() async throws {
        let (connection, _) = Self.seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.run("BEGIN", on: connection.id)
        let hold = try #require(Self.holds(connection.id).first)
        let key = DatabaseManager.shared.browsedGateKey(for: connection.id)
        let gate = AsyncGate()

        let turn = Task {
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(key) {
                await gate.wait()
            }
        }
        await gate.arrived(1)
        #expect(DatabaseManager.shared.isLaneBusy(holding: hold))
        await gate.open()
        try await turn.value

        #expect(!DatabaseManager.shared.isLaneBusy(holding: hold))
    }
}

// Answers its session state from the statements it saw, like a server that reports the flag in every reply.
private final class EndingScriptedDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PluginSessionTransactionState = .idle
    private var sent: [String] = []

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

    func sessionTransactionState() async -> PluginSessionTransactionState {
        lock.withLock { current }
    }

    func switchDatabase(to database: String) async throws {}
}
