//
//  DataWriteExecutorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// One test double for every case in this file: it records the order of everything it was asked to
/// do, reports whatever affected-row count the test wants, and can be told to fail on the Nth
/// statement.
private final class CountingDriver: PluginDriverStub, @unchecked Sendable {
    struct Failure: Error {}

    let affectedRows: Int
    let transactional: Bool
    /// One-based index of the statement that should throw, counting only the ones the plan runs.
    let failOnStatement: Int?
    let rollbackFails: Bool
    /// What the session answers when the executor asks what it is already holding.
    let sessionState: PluginSessionTransactionState

    /// Every call in the order it arrived: statement text, plus "BEGIN", "COMMIT", "ROLLBACK" and
    /// "open" or "close" with a session scope's purpose.
    private(set) var trace: [String] = []
    private var statementCount = 0

    var didCommit: Bool { trace.contains("COMMIT") }
    var didRollBack: Bool { trace.contains("ROLLBACK") }

    init(
        affectedRows: Int,
        transactional: Bool = true,
        failOnStatement: Int? = nil,
        rollbackFails: Bool = false,
        sessionState: PluginSessionTransactionState = .idle
    ) {
        self.affectedRows = affectedRows
        self.transactional = transactional
        self.failOnStatement = failOnStatement
        self.rollbackFails = rollbackFails
        self.sessionState = sessionState
    }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { transactional }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        trace.append(query)
        statementCount += 1
        if let failOnStatement, statementCount == failOnStatement { throw Failure() }
        return PluginQueryResult(
            columns: [], columnTypeNames: [], rows: [], rowsAffected: affectedRows, executionTime: 0
        )
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { sessionState }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        trace.append("open \(purpose)")
        return PluginSessionScope(purpose: purpose, saved: [], applied: [])
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        trace.append("close \(scope.purpose)")
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws { trace.append("BEGIN") }
    func commitTransaction() async throws { trace.append("COMMIT") }
    func rollbackTransaction() async throws {
        trace.append("ROLLBACK")
        if rollbackFails { throw Failure() }
    }
}

struct DataWriteExecutorTests {
    private func plan(
        expectedRowCount: Int?,
        statementCount: Int = 1,
        prologue: [String] = [],
        epilogue: [String] = [],
        matchesRowsWithoutKey: Bool = false,
        refusesSharedKey: Bool = false,
        databaseType: DatabaseType = .sqlite
    ) -> DataWritePlan {
        DataWritePlan(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            databaseType: databaseType,
            steps: (0 ..< statementCount).map { index in
                DataWriteStep(
                    kind: .rowWrite,
                    statement: ParameterizedStatement(sql: "UPDATE \"t\" SET \"b\" = \(index)", parameters: []),
                    expectedRowCount: expectedRowCount,
                    tableName: "t",
                    matchesRowsWithoutKey: matchesRowsWithoutKey,
                    refusesSharedKey: refusesSharedKey
                )
            },
            prologue: prologue,
            epilogue: epilogue
        )
    }

    private func driver(_ counting: CountingDriver) -> DatabaseDriver {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .sqlite), pluginDriver: counting)
    }

    @Test("The driver's real affected-row count reaches the caller")
    func reportsRealRowCount() async throws {
        let counting = CountingDriver(affectedRows: 42)
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: 50), on: driver(counting)).results

        #expect(results.first?.rowsAffected == 42)
        #expect(counting.didCommit)
    }

    @Test("A statement that matched more rows than the plan expected rolls the whole save back")
    func tooManyRowsRollsBack() async throws {
        let counting = CountingDriver(affectedRows: 2)
        await #expect(throws: DataWriteError.tooManyRowsAffected(table: "t", expected: 1, actual: 2)) {
            try await DataWriteExecutor.run(plan(expectedRowCount: 1), on: driver(counting))
        }
        #expect(counting.didRollBack)
        #expect(counting.didCommit == false)
    }

    @Test("Without transactions the extra rows are already written, and the error says so")
    func tooManyRowsWithoutTransactions() async throws {
        let counting = CountingDriver(affectedRows: 2, transactional: false)
        await #expect(
            throws: DataWriteError.tooManyRowsAffectedUnrecoverable(table: "t", expected: 1, actual: 2)
        ) {
            try await DataWriteExecutor.run(plan(expectedRowCount: 1), on: driver(counting))
        }
        #expect(counting.didRollBack == false)
    }

    @Test("Fewer rows than expected is an ordinary save, because MySQL reports zero for an unchanged value")
    func fewerRowsIsNotAFailure() async throws {
        let counting = CountingDriver(affectedRows: 0)
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: 1), on: driver(counting)).results

        #expect(results.first?.rowsAffected == 0)
        #expect(counting.didCommit)
        #expect(counting.didRollBack == false)
    }

    @Test("A keyless write that found no row is rolled back rather than reported as a save")
    func keylessWriteThatMatchedNothingFails() async throws {
        let counting = CountingDriver(affectedRows: 0)
        await #expect(throws: DataWriteError.rowsNoLongerMatch(table: "t", expected: 1, actual: 0)) {
            try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, matchesRowsWithoutKey: true),
                on: driver(counting)
            )
        }
        #expect(counting.didRollBack)
        #expect(counting.didCommit == false)
    }

    // The statement matched nothing because 5 and '5' both read as its key, or the row is gone.
    @Test("A SQLite key write that refuses a shared key and changed nothing fails, keeping the edit")
    func sharedKeyWriteThatMatchedNothingFails() async throws {
        let counting = CountingDriver(affectedRows: 0)
        await #expect(throws: DataWriteError.keyNoLongerMatchesOneRow(table: "t", expected: 1, actual: 0)) {
            try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, refusesSharedKey: true),
                on: driver(counting)
            )
        }
        #expect(counting.didRollBack)
        #expect(counting.didCommit == false)
    }

    @Test("A keyless delete that found only some of its rows fails on the ones it missed")
    func keylessDeleteThatMatchedSomeFails() async throws {
        let counting = CountingDriver(affectedRows: 2)
        await #expect(throws: DataWriteError.rowsNoLongerMatch(table: "t", expected: 3, actual: 2)) {
            try await DataWriteExecutor.run(
                plan(expectedRowCount: 3, matchesRowsWithoutKey: true),
                on: driver(counting)
            )
        }
        #expect(counting.didRollBack)
    }

    @Test("A KingbaseES keyless write that found no row is rolled back, as libpq reports a real count")
    func kingbaseKeylessWriteThatMatchedNothingFails() async throws {
        let counting = CountingDriver(affectedRows: 0)
        await #expect(throws: DataWriteError.rowsNoLongerMatch(table: "t", expected: 1, actual: 0)) {
            try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, matchesRowsWithoutKey: true, databaseType: .kingbasees),
                on: driver(counting)
            )
        }
        #expect(counting.didRollBack)
    }

    @Test("An engine whose driver reports no real count is not held to one")
    func keylessWriteOnAnEngineWithoutCountsSucceeds() async throws {
        let counting = CountingDriver(affectedRows: 0)
        let results = try await DataWriteExecutor.run(
            plan(expectedRowCount: 1, matchesRowsWithoutKey: true, databaseType: .clickhouse),
            on: driver(counting)
        ).results

        #expect(results.first?.rowsAffected == 0)
        #expect(counting.didCommit)
    }

    /// SQLite opens with foreign_keys off, and the epilogue alone would leave it on.
    @Test("The foreign-key disable runs before the transaction and the re-enable after it, inside a preserving scope")
    func togglesRunOutsideTheTransaction() async throws {
        let counting = CountingDriver(affectedRows: 1)
        _ = try await DataWriteExecutor.run(
            plan(
                expectedRowCount: 1,
                prologue: ["PRAGMA foreign_keys = OFF"],
                epilogue: ["PRAGMA foreign_keys = ON"]
            ),
            on: driver(counting)
        )

        #expect(counting.trace == [
            "open preserve",
            "PRAGMA foreign_keys = OFF",
            "BEGIN",
            "UPDATE \"t\" SET \"b\" = 0",
            "COMMIT",
            "PRAGMA foreign_keys = ON",
            "close preserve",
        ])
    }

    @Test("Foreign keys are re-enabled and the session's settings put back after a rollback too")
    func togglesRunAfterRollback() async throws {
        let counting = CountingDriver(affectedRows: 1, failOnStatement: 2)
        await #expect(throws: (any Error).self) {
            try await DataWriteExecutor.run(
                plan(
                    expectedRowCount: 1,
                    prologue: ["PRAGMA foreign_keys = OFF"],
                    epilogue: ["PRAGMA foreign_keys = ON"]
                ),
                on: driver(counting)
            )
        }

        #expect(counting.trace.first == "open preserve")
        #expect(Array(counting.trace.suffix(3)) == ["ROLLBACK", "PRAGMA foreign_keys = ON", "close preserve"])
    }

    /// PostgreSQL would put a `SET LOCAL` value back session-wide, where it outlives the user's transaction.
    @Test(
        "A save inside the user's transaction saves no session settings to put back",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction]
    )
    func saveInsideTheUsersTransactionOpensNoScope(state: PluginSessionTransactionState) async throws {
        let counting = CountingDriver(affectedRows: 1, sessionState: state)
        _ = try? await DataWriteExecutor.run(
            plan(
                expectedRowCount: 1,
                prologue: ["SET session_replication_role = replica"],
                epilogue: ["SET session_replication_role = origin"]
            ),
            on: driver(counting)
        )

        #expect(!counting.trace.contains("open preserve"))
        #expect(counting.trace.contains("SET session_replication_role = origin"))
    }

    @Test("A plan without a prologue leaves the session's settings alone")
    func planWithoutPrologueOpensNoScope() async throws {
        let counting = CountingDriver(affectedRows: 1)
        _ = try await DataWriteExecutor.run(plan(expectedRowCount: 1), on: driver(counting))

        #expect(counting.trace == ["BEGIN", "UPDATE \"t\" SET \"b\" = 0", "COMMIT"])
    }

    @Test
    func aRequiredPrologueThatFailsStopsTheRunBeforeAnyStep() async throws {
        let counting = CountingDriver(affectedRows: 1, failOnStatement: 1)
        let required = DataWritePlan(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            databaseType: .mssql,
            steps: plan(expectedRowCount: 1).steps,
            prologue: ["SET IDENTITY_INSERT [dbo].[t] ON"],
            epilogue: ["SET IDENTITY_INSERT [dbo].[t] OFF"],
            prologueIsRequired: true
        )
        await #expect(throws: (any Error).self) {
            try await DataWriteExecutor.run(required, on: driver(counting))
        }

        #expect(counting.trace == [
            "open preserve",
            "SET IDENTITY_INSERT [dbo].[t] ON",
            "SET IDENTITY_INSERT [dbo].[t] OFF",
            "close preserve",
        ])
        #expect(!counting.didCommit)
    }

    @Test
    func anOptionalPrologueThatFailsLetsTheStepsRun() async throws {
        let counting = CountingDriver(affectedRows: 1, failOnStatement: 1)
        _ = try await DataWriteExecutor.run(
            plan(expectedRowCount: 1, prologue: ["PRAGMA foreign_keys = OFF"]), on: driver(counting)
        )

        #expect(counting.didCommit)
    }

    @Test("The statements the run executed around the transaction are reported back")
    func sideStatementsAreReported() async throws {
        let counting = CountingDriver(affectedRows: 1)
        let run = try await DataWriteExecutor.run(
            plan(expectedRowCount: 1, prologue: ["A"], epilogue: ["B"]),
            on: driver(counting)
        )

        #expect(run.sideStatements == ["A", "B"])
    }

    @Test("Without transactions a failure halfway reports what already committed")
    func partialCommitCarriesTheCommittedResults() async throws {
        let counting = CountingDriver(affectedRows: 1, transactional: false, failOnStatement: 2)

        do {
            _ = try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, statementCount: 3), on: driver(counting)
            )
            Issue.record("expected the run to throw")
        } catch let error as DataWritePartialCommitError {
            #expect(error.committed.count == 1)
            #expect(error.totalStatements == 3)
        }
    }

    @Test("With transactions a failure halfway is an ordinary rollback, not a partial commit")
    func transactionalFailureIsNotPartial() async throws {
        let counting = CountingDriver(affectedRows: 1, failOnStatement: 2)

        do {
            _ = try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, statementCount: 3), on: driver(counting)
            )
            Issue.record("expected the run to throw")
        } catch is DataWritePartialCommitError {
            Issue.record("a rolled-back transaction left nothing committed")
        } catch {
            #expect(counting.didRollBack)
        }
    }

    /// A rollback that fails leaves the committed extent unknown, which is the same problem as
    /// having no transaction at all.
    @Test("A failed rollback is reported as a partial commit")
    func failedRollbackIsPartial() async throws {
        let counting = CountingDriver(affectedRows: 1, failOnStatement: 2, rollbackFails: true)

        do {
            _ = try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, statementCount: 3), on: driver(counting)
            )
            Issue.record("expected the run to throw")
        } catch let error as DataWritePartialCommitError {
            #expect(error.committed.count == 1)
        }
    }

    @Test("A statement whose row count carries no meaning is not held to one")
    func unverifiedStepIsNotChecked() async throws {
        let counting = CountingDriver(affectedRows: 9_999)
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: nil), on: driver(counting)).results

        #expect(results.first?.wasVerified == false)
        #expect(counting.didCommit)
    }

    @Test(
        "A save joins a transaction the session already holds instead of committing it",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .holdsSessionLocks]
    )
    func saveJoinsTheSessionTransaction(state: PluginSessionTransactionState) async throws {
        let counting = CountingDriver(affectedRows: 1, sessionState: state)
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: 1), on: driver(counting)).results

        #expect(results.first?.rowsAffected == 1)
        #expect(counting.trace == ["UPDATE \"t\" SET \"b\" = 0"])
    }

    @Test("A session that reports nothing open is still wrapped, and so is one that cannot say")
    func saveWrapsWhenNothingIsOpen() async throws {
        for state in [PluginSessionTransactionState.idle, .unknown] {
            let counting = CountingDriver(affectedRows: 1, sessionState: state)
            _ = try await DataWriteExecutor.run(plan(expectedRowCount: 1), on: driver(counting))
            #expect(counting.trace.first == "BEGIN")
            #expect(counting.didCommit)
        }
    }

    @Test("A failure inside the user's transaction reports the statements as pending, not written")
    func failureInsideTheSessionTransactionIsPending() async throws {
        let counting = CountingDriver(affectedRows: 1, failOnStatement: 2, sessionState: .inTransaction)

        do {
            _ = try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, statementCount: 3), on: driver(counting)
            )
            Issue.record("expected the run to throw")
        } catch let error as DataWritePartialCommitError {
            #expect(error.disposition == .pendingInSessionTransaction)
            #expect(error.committed.count == 1)
            #expect(counting.didRollBack == false)
            #expect(error.partialCommitMessage.contains("already open on this connection"))
        }
    }

    @Test("Too many rows inside the user's transaction blames neither a rollback nor the engine")
    func tooManyRowsInsideTheSessionTransaction() async throws {
        let counting = CountingDriver(affectedRows: 2, sessionState: .inTransaction)
        await #expect(
            throws: DataWriteError.tooManyRowsAffectedInSessionTransaction(table: "t", expected: 1, actual: 2)
        ) {
            try await DataWriteExecutor.run(plan(expectedRowCount: 1), on: driver(counting))
        }
        #expect(counting.didRollBack == false)
    }
}

struct WriteTransactionOwnerTests {
    @Test("An engine without transactions is nobody's to wrap")
    func withoutTransactionsNobodyOwnsOne() {
        for state in [
            PluginSessionTransactionState.idle, .inTransaction, .abortedTransaction, .holdsSessionLocks, .unknown,
        ] {
            let owner = WriteTransactionOwner.resolve(supportsTransactions: false, sessionState: state)
            #expect(owner == WriteTransactionOwner.none)
            #expect(owner.opensTransaction == false)
            #expect(owner.canRollBack == false)
        }
    }

    @Test(
        "A session holding a transaction or a lock owns it",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .holdsSessionLocks]
    )
    func sessionOwnsWhatItHolds(state: PluginSessionTransactionState) {
        let owner = WriteTransactionOwner.resolve(supportsTransactions: true, sessionState: state)
        #expect(owner == .session)
        #expect(owner.opensTransaction == false)
        #expect(owner.canRollBack == false)
    }

    @Test("The app owns the transaction when nothing is open, and when the driver cannot say")
    func appOwnsTheRest() {
        for state in [PluginSessionTransactionState.idle, .unknown] {
            let owner = WriteTransactionOwner.resolve(supportsTransactions: true, sessionState: state)
            #expect(owner == .app)
            #expect(owner.opensTransaction)
            #expect(owner.canRollBack)
        }
    }
}
