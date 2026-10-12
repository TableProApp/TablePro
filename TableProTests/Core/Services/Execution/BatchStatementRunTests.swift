//
//  BatchStatementRunTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct BatchStatementRunTests {
    private static let statements = ["INSERT INTO t VALUES (1)", "VACUUM", "SELECT 1"]

    private static func run(
        plan: BatchTransactionPlan,
        driver: TransactionRecordingDriver,
        probe: ClaimProbe? = nil,
        statements: [String] = Self.statements,
        commitPoints: Set<String> = [],
        failing: String? = nil,
        stopsAfter: Int = .max
    ) async -> BatchStatementOutcome<QueryResult> {
        let claims = probe ?? ClaimProbe()
        return await BatchStatementRun.run(
            statements,
            plan: plan,
            mode: .readWrite,
            driver: driver,
            connectionId: claims.connectionId,
            gate: claims.gate,
            failureSQL: { $0 },
            isCommitPoint: { commitPoints.contains($0) }
        ) { statement in
            if claims.recordExecution() == stopsAfter { claims.stop() }
            if statement == failing { throw TestError.refused }
            return try await driver.execute(query: statement)
        }
    }

    @Test("A batch running in autocommit opens nothing and takes nothing back")
    func autocommitTouchesNoTransaction() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .autocommit, driver: driver)
        #expect(driver.events.isEmpty)
        guard case .completed(let results) = outcome else {
            Issue.record("expected a completed run, got \(outcome)")
            return
        }
        #expect(results.count == 3)
    }

    @Test("A failure in autocommit rolls nothing back and keeps what already ran")
    func autocommitFailureKeepsItsResults() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .autocommit, driver: driver, failing: "VACUUM")
        #expect(driver.events.isEmpty)
        guard case .failed(let results, let failure, _) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(results.count == 1)
        #expect(failure == .statement(sql: "VACUUM"))
    }

    /// A SQL Server batch carries on past most errors, so it answers rather than throws, and what it returned before
    /// and after the error is real. The run stops there and keeps that answer as the last of its results.
    @Test("A unit that answers with a server error fails the run and keeps its own answer")
    func serverErrorFailsTheRunAndKeepsTheAnswer() async {
        let driver = TransactionRecordingDriver()
        let claims = ClaimProbe()
        let outcome = await BatchStatementRun.run(
            ["batch 1", "batch 2", "batch 3"],
            plan: .autocommit,
            mode: .readWrite,
            driver: driver,
            connectionId: claims.connectionId,
            gate: claims.gate,
            failureSQL: { $0 },
            isCommitPoint: { _ in false },
            serverError: { (answer: String) in answer == "batch 2 answered" ? "Line 1: boom" : nil }
        ) { unit in
            "\(unit) answered"
        }
        #expect(driver.events.isEmpty)
        guard case .failed(let answers, let failure, let description) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(answers == ["batch 1 answered", "batch 2 answered"])
        #expect(failure == .batch(sql: "batch 2"))
        #expect(description == "Line 1: boom")
    }

    @Test("A Stop in autocommit keeps the results of the statements that already committed")
    func autocommitStopKeepsItsResults() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .autocommit, driver: driver, stopsAfter: 2)
        #expect(driver.events.isEmpty)
        guard case .cancelled(let results) = outcome else {
            Issue.record("expected a cancelled run, got \(outcome)")
            return
        }
        #expect(results.count == 2)
    }

    @Test("The app's own transaction is opened with the mode it was given and committed")
    func appTransactionBeginsAndCommits() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .appTransaction, driver: driver)
        #expect(driver.events == [.begin(mode: .readWrite), .commit])
        guard case .completed = outcome else {
            Issue.record("expected a completed run, got \(outcome)")
            return
        }
    }

    @Test("The app's own transaction is rolled back on a failure, and its results are dropped")
    func appTransactionRollsBackAFailure() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .appTransaction, driver: driver, failing: "VACUUM")
        #expect(driver.events == [.begin(mode: .readWrite), .rollback])
        guard case .failed(let results, _, _) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(results.count == 1)
    }

    @Test("A Stop rolls the app's own transaction back and keeps no results")
    func appTransactionRollsBackAStop() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .appTransaction, driver: driver, stopsAfter: 1)
        #expect(driver.events == [.begin(mode: .readWrite), .rollback])
        guard case .cancelled(let results) = outcome else {
            Issue.record("expected a cancelled run, got \(outcome)")
            return
        }
        #expect(results.isEmpty)
    }

    @Test("A transaction that will not start blames the start and runs no statement")
    func failedStartRunsNothing() async {
        let driver = TransactionRecordingDriver(failsBegin: true)
        let outcome = await Self.run(plan: .appTransaction, driver: driver)
        #expect(driver.events == [.begin(mode: .readWrite)])
        guard case .failed(let results, let failure, _) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(results.isEmpty)
        #expect(failure == .transactionStart)
    }

    @Test("A commit the server refused is rolled back")
    func failedCommitRollsBack() async {
        let driver = TransactionRecordingDriver(failsCommit: true)
        let outcome = await Self.run(plan: .appTransaction, driver: driver)
        #expect(driver.events == [.begin(mode: .readWrite), .commit, .rollback])
        guard case .failed(_, let failure, _) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(failure == .commit)
    }

    @Test("A script that manages its own transaction is neither begun nor committed by the app")
    func scriptTransactionIsLeftAlone() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .scriptTransaction, driver: driver)
        #expect(driver.events.isEmpty)
        guard case .completed = outcome else {
            Issue.record("expected a completed run, got \(outcome)")
            return
        }
    }

    @Test("A failed script still has whatever it left open rolled back")
    func scriptTransactionRollsBackAFailure() async {
        let driver = TransactionRecordingDriver()
        _ = await Self.run(plan: .scriptTransaction, driver: driver, failing: "VACUUM")
        #expect(driver.events == [.rollback])
    }

    @Test("A stopped script has whatever it left open rolled back")
    func scriptTransactionRollsBackAStop() async {
        let driver = TransactionRecordingDriver()
        _ = await Self.run(plan: .scriptTransaction, driver: driver, stopsAfter: 1)
        #expect(driver.events == [.rollback])
    }

    @Test("A run that joined the session's transaction sends no BEGIN, COMMIT or ROLLBACK")
    func sessionTransactionIsNeverTouched() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .sessionTransaction, driver: driver)
        #expect(driver.events.isEmpty)
        guard case .completed = outcome else {
            Issue.record("expected a completed run, got \(outcome)")
            return
        }
    }

    @Test("A failure inside the session's transaction leaves it open and keeps what ran")
    func sessionTransactionFailureLeavesItOpen() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .sessionTransaction, driver: driver, failing: "VACUUM")
        #expect(driver.events.isEmpty)
        guard case .failed(let results, _, _) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(results.count == 1)
    }

    @Test("A Stop inside the session's transaction rolls nothing back and keeps what ran")
    func sessionTransactionStopLeavesItOpen() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .sessionTransaction, driver: driver, stopsAfter: 2)
        #expect(driver.events.isEmpty)
        guard case .cancelled(let results) = outcome else {
            Issue.record("expected a cancelled run, got \(outcome)")
            return
        }
        #expect(results.count == 2)
    }

    @Test(
        "A driver without transactions is never asked to begin, commit or roll back",
        arguments: [BatchTransactionPlan.appTransaction, .scriptTransaction, .autocommit, .sessionTransaction]
    )
    func driversWithoutTransactionsAreLeftAlone(plan: BatchTransactionPlan) async {
        let driver = TransactionRecordingDriver(supportsTransactions: false)
        _ = await Self.run(plan: plan, driver: driver, failing: "VACUUM")
        #expect(driver.events.isEmpty)
    }

    // MARK: - The commit point

    /// The defect. Stop lands while the commit is on the wire, the commit still goes through, and
    /// the batch reports what the server answered instead of pretending it was taken back.
    @Test("A Stop during the commit neither kills it nor drops its results")
    func stopDuringTheCommitIsTooLate() async {
        let probe = ClaimProbe()
        let driver = TransactionRecordingDriver()
        driver.whileCommitting = { probe.stop() }

        let outcome = await Self.run(plan: .appTransaction, driver: driver, probe: probe)

        #expect(driver.events == [.begin(mode: .readWrite), .commit])
        guard case .completed(let results) = outcome else {
            Issue.record("expected a completed run, got \(outcome)")
            return
        }
        #expect(results.count == 3)
        #expect(probe.isCurrent)
        #expect(probe.settle())
    }

    /// The other side of the same instant. Stop landed before the commit was sent, so the batch
    /// rolls back and reports itself stopped.
    @Test("A Stop before the commit rolls back and never sends it")
    func stopBeforeTheCommitRollsBack() async {
        let driver = TransactionRecordingDriver()
        let outcome = await Self.run(plan: .appTransaction, driver: driver, stopsAfter: 3)
        #expect(driver.events == [.begin(mode: .readWrite), .rollback])
        guard case .cancelled = outcome else {
            Issue.record("expected a cancelled run, got \(outcome)")
            return
        }
    }

    /// The mark is held past the commit deliberately: between the server's answer and the settle
    /// there is no statement left to stop, and a Stop in that gap would drop results the server has
    /// already kept.
    @Test("The claim stays marked after the app's own commit, until it settles")
    func theAppsCommitHoldsTheMarkUntilSettle() async {
        let probe = ClaimProbe()
        _ = await Self.run(plan: .appTransaction, driver: TransactionRecordingDriver(), probe: probe)

        #expect(probe.isStoppable == false)
        #expect(probe.commitPhaseExits == 0)
        #expect(probe.settle())
    }

    /// A commit whose connection died is not a rollback, and must not be reported as one: measured
    /// on MySQL 8.4.11, a commit blocked under a read lock survived `kill -9` of the client and
    /// committed once the lock was released.
    @Test("A commit that lost the connection reports an unknown outcome and sends no rollback")
    func lostConnectionDuringCommitIsUnknown() async {
        let driver = TransactionRecordingDriver(failsCommit: true)
        driver.commitError = DatabaseError.queryFailed("Lost connection to MySQL server during query")

        let outcome = await Self.run(plan: .appTransaction, driver: driver)

        #expect(driver.events == [.begin(mode: .readWrite), .commit])
        guard case .failed(let results, let failure, let description) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(failure == .commitOutcomeUnknown)
        #expect(results.count == 3)
        #expect(description.contains("Lost connection"))
    }

    /// The driver's own verdict counts too, for an engine whose message says nothing useful.
    @Test("A driver that reports a lost connection makes the commit outcome unknown")
    func driverReportedLossIsUnknown() async {
        let driver = TransactionRecordingDriver(failsCommit: true)
        driver.hasLostConnection = true

        let outcome = await Self.run(plan: .appTransaction, driver: driver)

        #expect(driver.events == [.begin(mode: .readWrite), .commit])
        guard case .failed(_, let failure, _) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(failure == .commitOutcomeUnknown)
    }

    // MARK: - A script's own commit

    @Test("A script's own COMMIT goes through the commit point, and the batch is stoppable again")
    func scriptCommitIsProtectedAndThenReleased() async {
        let probe = ClaimProbe()
        let driver = TransactionRecordingDriver()

        let outcome = await Self.run(
            plan: .scriptTransaction,
            driver: driver,
            probe: probe,
            statements: ["INSERT INTO t VALUES (1)", "COMMIT", "INSERT INTO t VALUES (2)"],
            commitPoints: ["COMMIT"]
        )

        #expect(driver.events.isEmpty)
        #expect(probe.commitPhaseEntries == 1)
        #expect(probe.commitPhaseExits == 1)
        #expect(probe.isStoppable)
        guard case .completed(let results) = outcome else {
            Issue.record("expected a completed run, got \(outcome)")
            return
        }
        #expect(results.count == 3)
    }

    @Test("A Stop during a script's own COMMIT keeps the claim, so the run can still report itself")
    func stopDuringAScriptCommitKeepsTheClaim() async {
        let probe = ClaimProbe()
        let driver = TransactionRecordingDriver()
        probe.whileEnteringCommitPhase = { probe.stop() }

        _ = await Self.run(
            plan: .scriptTransaction,
            driver: driver,
            probe: probe,
            statements: ["INSERT INTO t VALUES (1)", "COMMIT"],
            commitPoints: ["COMMIT"]
        )

        #expect(probe.isCurrent)
        #expect(probe.settle())
    }

    @Test("A script's COMMIT that lost the connection reports an unknown outcome, not a statement failure")
    func scriptCommitLostConnectionIsUnknown() async {
        let driver = TransactionRecordingDriver()
        driver.failingStatements = ["COMMIT": DatabaseError.queryFailed("MySQL server has gone away")]

        let outcome = await Self.run(
            plan: .scriptTransaction,
            driver: driver,
            statements: ["INSERT INTO t VALUES (1)", "COMMIT"],
            commitPoints: ["COMMIT"]
        )

        #expect(driver.events.isEmpty)
        guard case .failed(_, let failure, _) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(failure == .commitOutcomeUnknown)
    }

    @Test("A script's COMMIT the server refused is an ordinary statement failure, and rolls back")
    func scriptCommitRefusalIsAStatementFailure() async {
        let driver = TransactionRecordingDriver()
        driver.failingStatements = ["COMMIT": DatabaseError.queryFailed("cannot commit - no transaction is active")]

        let outcome = await Self.run(
            plan: .scriptTransaction,
            driver: driver,
            statements: ["INSERT INTO t VALUES (1)", "COMMIT"],
            commitPoints: ["COMMIT"]
        )

        #expect(driver.events == [.rollback])
        guard case .failed(_, let failure, _) = outcome else {
            Issue.record("expected a failed run, got \(outcome)")
            return
        }
        #expect(failure == .statement(sql: "COMMIT"))
    }

    // MARK: - Protection and the shield

    /// Stop reaches the driver through `cancelRunningQuery`, which reads the registered handles.
    /// While the commit is in flight the batch's own handle is registered as a protected write, so
    /// the cancel skips it even though the statements' cancellable lease is still open around it.
    @Test("The handle is unreachable by Stop while the commit is in flight")
    func theCommitHandleIsProtected() async {
        let probe = ClaimProbe()
        let driver = TransactionRecordingDriver()
        let lease = DriverLeaseOwner()
        DatabaseManager.shared.runningDrivers[probe.connectionId] = [
            UUID(): RunningDriver(driver: driver, policy: .cancellableRead(lease))
        ]
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: probe.connectionId) }

        driver.whileCommitting = {
            try? DatabaseManager.shared.cancelRunningQuery(
                owner: lease, on: probe.connectionId, delivery: .immediate
            )
        }

        _ = await Self.run(plan: .appTransaction, driver: driver, probe: probe)

        #expect(driver.cancelCount == 0)
        #expect(driver.events == [.begin(mode: .readWrite), .commit])
    }

    /// The same handle is reachable again the moment the commit is over, so nothing is left
    /// permanently uncancellable.
    @Test("The protection is released when the commit returns")
    func protectionIsReleasedAfterTheCommit() async {
        let probe = ClaimProbe()
        let driver = TransactionRecordingDriver()
        _ = await Self.run(plan: .appTransaction, driver: driver, probe: probe)

        #expect(DatabaseManager.shared.runningDrivers[probe.connectionId] == nil)
        #expect(DatabaseManager.shared.holdsProtectedWrite(probe.connectionId) == false)
    }

    /// `Task.cancel()` reaches every child of the cancelled task, and a driver that reads it aborts
    /// before the statement is sent. The commit is not a child, so it never sees it.
    @Test("A commit already on the wire does not see the cancellation of the task awaiting it")
    func theCommitIsShieldedFromTaskCancellation() async {
        let driver = TransactionRecordingDriver()
        let holder = TaskHolder()
        let start = TestLatch()
        driver.whileCommitting = { holder.cancel() }

        let task = Task { @MainActor in
            await start.wait()
            return await Self.run(plan: .appTransaction, driver: driver)
        }
        holder.task = task
        start.open()
        let outcome = await task.value

        #expect(driver.commitSawCancellation == false)
        #expect(driver.events == [.begin(mode: .readWrite), .commit])
        guard case .completed = outcome else {
            Issue.record("expected a completed run, got \(outcome)")
            return
        }
    }

    /// The rollback after a Stop is the other statement that has to survive the cancel that asked
    /// for it. Dameng never sends one issued inside a cancelled task at all.
    @Test("The rollback a Stop asks for does not see the cancellation either")
    func theRollbackIsShieldedFromTaskCancellation() async {
        let driver = TransactionRecordingDriver()
        let holder = TaskHolder()
        let start = TestLatch()
        driver.whileExecuting = { holder.cancel() }

        let task = Task { @MainActor in
            await start.wait()
            return await Self.run(plan: .appTransaction, driver: driver)
        }
        holder.task = task
        start.open()
        let outcome = await task.value

        #expect(driver.events == [.begin(mode: .readWrite), .rollback])
        #expect(driver.rollbackSawCancellation == false)
        guard case .cancelled = outcome else {
            Issue.record("expected a cancelled run, got \(outcome)")
            return
        }
    }
}

private enum TestError: Error {
    case refused
}

/// A real registry behind the gate, so the order Stop and the commit mark land in is the order the
/// app's is, rather than a pair of closures a test wrote to agree with itself.
@MainActor
private final class ClaimProbe {
    let connectionId = UUID()
    private var registry: TabExecutionRegistry
    private let claim: TabExecutionClaim
    private let tabId: UUID
    private var executions = 0

    private(set) var commitPhaseEntries = 0
    private(set) var commitPhaseExits = 0

    /// Fires after the claim has been marked, which is where a Stop that lands during the commit
    /// has to be delivered for the test to mean anything.
    var whileEnteringCommitPhase: (() -> Void)?

    init() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        claim = registry.claim(tabId)
        self.registry = registry
        self.tabId = tabId
    }

    var gate: BatchClaimGate {
        BatchClaimGate(
            isCurrent: { self.registry.isCurrent(self.claim) },
            enterCommitPhase: { self.enterCommitPhase() },
            leaveCommitPhase: { self.leaveCommitPhase() }
        )
    }

    var isCurrent: Bool { registry.isCurrent(claim) }
    var isStoppable: Bool { registry.isStoppable(tabId) }

    func recordExecution() -> Int {
        executions += 1
        return executions
    }

    func stop() {
        _ = registry.stop(tabId)
    }

    func settle() -> Bool {
        registry.settle(claim)
    }

    private func enterCommitPhase() -> Bool {
        commitPhaseEntries += 1
        let entered = registry.enterUninterruptiblePhase(claim)
        whileEnteringCommitPhase?()
        return entered
    }

    private func leaveCommitPhase() {
        commitPhaseExits += 1
        registry.leaveUninterruptiblePhase(claim)
    }
}

@MainActor
private final class TaskHolder {
    var task: Task<BatchStatementOutcome<QueryResult>, Never>?

    func cancel() {
        task?.cancel()
    }
}

@MainActor
private final class TestLatch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private enum TransactionEvent: Equatable {
    case begin(mode: PluginTransactionAccessMode)
    case commit
    case rollback
}

/// Records the transaction calls one run makes, in order. Everything else answers empty: the run
/// under test executes statements through the closure it is given, not through the driver.
private final class TransactionRecordingDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }
    let supportsTransactions: Bool
    var hasLostConnection = false

    private(set) var events: [TransactionEvent] = []
    private(set) var cancelCount = 0
    private(set) var commitSawCancellation = false
    private(set) var rollbackSawCancellation = false

    /// What each statement the run executes through this driver should throw, by its text. Only the
    /// commit-point cases use it: everything else fails through the run's own closure.
    var failingStatements: [String: Error] = [:]
    var commitError: Error = TestError.refused
    /// Run on the main actor from inside the commit, which is the only window a Stop has left.
    var whileCommitting: (@MainActor @Sendable () -> Void)?
    /// Run on the main actor from inside the first statement.
    var whileExecuting: (@MainActor @Sendable () -> Void)?

    private let failsBegin: Bool
    private let failsCommit: Bool
    private var executedStatements = 0

    init(supportsTransactions: Bool = true, failsBegin: Bool = false, failsCommit: Bool = false) {
        connection = TestFixtures.makeConnection(type: .sqlite)
        self.supportsTransactions = supportsTransactions
        self.failsBegin = failsBegin
        self.failsCommit = failsCommit
    }

    func beginTransaction() async throws {
        try await beginTransaction(mode: .readWrite)
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        events.append(.begin(mode: mode))
        if failsBegin { throw TestError.refused }
    }

    func commitTransaction() async throws {
        events.append(.commit)
        commitSawCancellation = Task.isCancelled
        if let hook = whileCommitting { await MainActor.run { hook() } }
        commitSawCancellation = commitSawCancellation || Task.isCancelled
        if failsCommit { throw commitError }
    }

    func rollbackTransaction() async throws {
        events.append(.rollback)
        rollbackSawCancellation = Task.isCancelled
    }

    func cancelQuery() throws {
        cancelCount += 1
    }

    func execute(query: String) async throws -> QueryResult {
        executedStatements += 1
        if executedStatements == 1, let hook = whileExecuting { await MainActor.run { hook() } }
        if let error = failingStatements[query] { throw error }
        return .empty
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { .empty }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult { .empty }
    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchViewDefinition(view: String) async throws -> String { "" }

    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database,
            name: database,
            tableCount: nil,
            sizeBytes: nil,
            lastAccessed: nil,
            isSystemDatabase: false,
            icon: "cylinder"
        )
    }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: nil,
            comment: nil,
            engine: nil,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }
}
