//
//  QuitTransactionPromptTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite(.serialized)
@MainActor
struct QuitTransactionPromptTests {
    private static func seed(name: String) -> (connection: DatabaseConnection, driver: QuitStubDriver) {
        let connection = TestFixtures.makeConnection(name: name, database: "app", type: .mysql)
        let driver = QuitStubDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = "app"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private static func begin(on connectionId: UUID) async throws {
        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: DatabaseScope(connectionId: connectionId, database: "app", schema: nil),
            route: .sessionDriver,
            cancellation: .protectedWrite
        ) { driver in
            try await driver.execute(query: "BEGIN")
        }
    }

    private static func plan(
        registry: RunningWorkRegistry,
        hasUnsavedTabs: Bool = false,
        answer: AlertHelper.TransactionEndAnswer,
        asked: inout [TransactionEndPrompt]
    ) -> QuitPlan? {
        var seen: [TransactionEndPrompt] = []
        let plan = QuitApproval.approvesStoppingWork(
            registry: registry,
            action: .quit,
            hasUnsavedTabs: { hasUnsavedTabs },
            confirmWork: { _ in true },
            answerTransaction: { prompt in
                seen.append(prompt)
                return answer
            },
            confirmDiscardingTabs: { _ in
                Issue.record("The transaction prompt already named the unsaved tabs")
                return false
            }
        )
        asked = seen
        return plan
    }

    @Test("Each connection holding a transaction is named once, whatever its lanes")
    func holdsAreNamedOncePerConnection() {
        let prod = UUID()
        let staging = UUID()
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: QuitStubDriver())
        let tracker = SessionTransactionTracker { _, _ in true }
        tracker.record(.inTransaction, on: driver, for: .init(connectionId: prod, lane: "sales"))
        tracker.record(.abortedTransaction, on: driver, for: .init(connectionId: prod, lane: "hr"))
        tracker.record(.inTransaction, on: driver, for: .init(connectionId: staging, lane: nil))
        let names = [prod: "Prod", staging: "Staging"]

        let named = QuitApproval.openTransactionNames(
            holds: Array(tracker.holds.values),
            connectionName: { names[$0] }
        )

        #expect(named == ["Prod", "Staging"])
    }

    @Test("Commit on the quit prompt plans the commits and stops no work yet")
    func commitPlansTheHolds() async throws {
        let (connection, _) = Self.seed(name: "Prod")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.begin(on: connection.id)
        var stopped = 0
        let registry = RunningWorkRegistry(providers: [])
        registry.begin(.restore, subject: "sales", connectionName: "Prod", connectionIds: [connection.id]) { stopped += 1 }
        var asked: [TransactionEndPrompt] = []

        let plan = try #require(Self.plan(registry: registry, answer: .commit, asked: &asked))

        #expect(asked.count == 1)
        #expect(asked.first?.offersCommit == true)
        #expect(asked.first?.message.contains("“Prod”") == true)
        #expect(plan.commits.contains { $0.connectionId == connection.id })
        #expect(plan.work.count == 1)
        #expect(stopped == 0)
    }

    // Quitting ends the session, and the server rolls back what it held.
    @Test("Roll Back on the quit prompt plans no commit")
    func rollBackPlansNothing() async throws {
        let (connection, _) = Self.seed(name: "Prod")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.begin(on: connection.id)
        var asked: [TransactionEndPrompt] = []

        let plan = try #require(Self.plan(registry: RunningWorkRegistry(providers: []), answer: .rollBack, asked: &asked))

        #expect(plan.commits.isEmpty)
    }

    @Test("Cancel on the quit prompt keeps the app open")
    func cancelKeepsTheAppOpen() async throws {
        let (connection, _) = Self.seed(name: "Prod")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.begin(on: connection.id)
        var asked: [TransactionEndPrompt] = []

        #expect(Self.plan(registry: RunningWorkRegistry(providers: []), answer: .cancel, asked: &asked) == nil)
    }

    @Test("Unsaved tabs ride along on the transaction question rather than asking again")
    func unsavedTabsRideAlong() async throws {
        let (connection, _) = Self.seed(name: "Prod")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.begin(on: connection.id)
        var asked: [TransactionEndPrompt] = []

        _ = Self.plan(registry: RunningWorkRegistry(providers: []), hasUnsavedTabs: true, answer: .rollBack, asked: &asked)

        #expect(asked.first?.message.hasSuffix("Some tabs have unsaved edits. Quitting will discard these changes.") == true)
    }

    @Test("The commit lands before the quit goes ahead")
    func commitBeforeQuittingCommits() async throws {
        let (connection, driver) = Self.seed(name: "Prod")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.begin(on: connection.id)
        let plan = QuitPlan(commits: DatabaseManager.shared.sessionTransactions.holds(for: connection.id), work: [])
        var failures: [String] = []

        let quits = await QuitApproval.commitBeforeQuitting(
            plan,
            commit: { try await ConnectionTransactionActions.commitBeforeEnding($0, gate: AlwaysAllowGate()) },
            reportFailure: { failures.append($0) }
        )

        #expect(quits)
        #expect(driver.statements.last == "COMMIT")
        #expect(failures.isEmpty)
    }

    @Test("Cancelling the Safe Mode question keeps the app open and says nothing")
    func gateCancelKeepsTheAppOpen() async throws {
        let (connection, driver) = Self.seed(name: "Prod")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.begin(on: connection.id)
        let plan = QuitPlan(commits: DatabaseManager.shared.sessionTransactions.holds(for: connection.id), work: [])
        var failures: [String] = []

        let quits = await QuitApproval.commitBeforeQuitting(
            plan,
            commit: { try await ConnectionTransactionActions.commitBeforeEnding($0, gate: AlwaysDenyGate.cancelling) },
            reportFailure: { failures.append($0) }
        )

        #expect(!quits)
        #expect(!driver.statements.contains("COMMIT"))
        #expect(failures.isEmpty)
    }

    @Test("A failed commit keeps the app open and shows why")
    func failedCommitKeepsTheAppOpen() async throws {
        let (connection, _) = Self.seed(name: "Prod")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.begin(on: connection.id)
        let plan = QuitPlan(commits: DatabaseManager.shared.sessionTransactions.holds(for: connection.id), work: [])
        var failures: [String] = []

        let quits = await QuitApproval.commitBeforeQuitting(
            plan,
            commit: { _ in throw SessionTransactionActionError.cannotCommit },
            reportFailure: { failures.append($0) }
        )

        #expect(!quits)
        #expect(failures == [SessionTransactionActionError.cannotCommit.localizedDescription])
    }

    // A nested Teradata BT survives one END TRANSACTION; quitting after it would roll back what was committed.
    @Test("A transaction still open after the commit keeps the app open and names its connection")
    func stillOpenKeepsTheAppOpen() async throws {
        let (connection, _) = Self.seed(name: "Prod")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await Self.begin(on: connection.id)
        let plan = QuitPlan(commits: DatabaseManager.shared.sessionTransactions.holds(for: connection.id), work: [])
        var failures: [String] = []

        let quits = await QuitApproval.commitBeforeQuitting(
            plan,
            commit: { _ in true },
            reportFailure: { failures.append($0) }
        )

        #expect(!quits)
        #expect(failures.count == 1)
        #expect(failures.first?.contains("“Prod”") == true)
    }

    @Test("Nothing to commit quits without touching the server")
    func nothingToCommitQuits() async {
        let quits = await QuitApproval.commitBeforeQuitting(
            QuitPlan(commits: [], work: []),
            commit: { _ in
                Issue.record("Nothing to commit")
                return false
            },
            reportFailure: { _ in Issue.record("Nothing failed") }
        )

        #expect(quits)
    }
}

private final class QuitStubDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PluginSessionTransactionState = .idle
    private var sent: [String] = []

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }
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
