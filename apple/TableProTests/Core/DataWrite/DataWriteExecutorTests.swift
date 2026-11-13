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
        rowKind: RowWriteKind? = nil,
        databaseType: DatabaseType = .sqlite,
        countsMatchedRows: Bool = false
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
                    refusesSharedKey: refusesSharedKey,
                    rowKind: rowKind,
                    countsMatchedRows: countsMatchedRows
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
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: 50), commitMode: .automatic, on: driver(counting)).results

        #expect(results.first?.rowsAffected == 42)
        #expect(counting.didCommit)
    }

    @Test("A statement that matched more rows than the plan expected rolls the whole save back")
    func tooManyRowsRollsBack() async throws {
        let counting = CountingDriver(affectedRows: 2)
        await #expect(throws: DataWriteError.tooManyRowsAffected(table: "t", expected: 1, actual: 2)) {
            try await DataWriteExecutor.run(plan(expectedRowCount: 1), commitMode: .automatic, on: driver(counting))
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
            try await DataWriteExecutor.run(plan(expectedRowCount: 1), commitMode: .automatic, on: driver(counting))
        }
        #expect(counting.didRollBack == false)
    }

    @Test("A keyed UPDATE short of its rows is an ordinary save where nothing says the count is the rows matched")
    func fewerRowsIsNotAFailure() async throws {
        let counting = CountingDriver(affectedRows: 0)
        let results = try await DataWriteExecutor.run(
            plan(expectedRowCount: 1, rowKind: .update, databaseType: .snowflake),
            commitMode: .automatic, on: driver(counting)
        ).results

        #expect(results.first?.rowsAffected == 0)
        #expect(counting.didCommit)
        #expect(counting.didRollBack == false)
    }

    @Test("A keyed UPDATE that matched no row fails where the count is the rows matched")
    func keyedUpdateThatMatchedNothingFails() async throws {
        let engines: [DatabaseType] = [.postgresql, .sqlite, .duckdb, .mysql, .mariadb, .tidb, .oceanbase]
        for databaseType in engines {
            let counting = CountingDriver(affectedRows: 0)
            await #expect(throws: DataWriteError.self) {
                try await DataWriteExecutor.run(
                    plan(expectedRowCount: 1, rowKind: .update, databaseType: databaseType),
                    commitMode: .automatic, on: driver(counting)
                )
            }
            #expect(counting.didRollBack)
            #expect(counting.didCommit == false)
        }
    }

    @Test("A driver's own matched-row count holds a keyed UPDATE on an engine the host keeps no count for")
    func driverCountHoldsAKeyedUpdate() async throws {
        let counting = CountingDriver(affectedRows: 0)
        await #expect(throws: DataWriteError.self) {
            try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, rowKind: .update, databaseType: .snowflake, countsMatchedRows: true),
                commitMode: .automatic, on: driver(counting)
            )
        }
        #expect(counting.didRollBack)
        #expect(counting.didCommit == false)
    }

    @Test("A driver's own count leaves a keyed DELETE of a row already gone an ordinary save")
    func driverCountLeavesAGoneRowsDeleteAlone() async throws {
        let counting = CountingDriver(affectedRows: 0)
        _ = try await DataWriteExecutor.run(
            plan(expectedRowCount: 1, rowKind: .delete, databaseType: .snowflake, countsMatchedRows: true),
            commitMode: .automatic, on: driver(counting)
        )

        #expect(counting.didCommit)
    }

    @Test("A driver's own count through a view keeps the lenient rule")
    func driverCountThroughAViewStaysLenient() async throws {
        let counting = CountingDriver(affectedRows: 0)
        var viewPlan = plan(expectedRowCount: 1, rowKind: .update, databaseType: .mssql, countsMatchedRows: true)
        viewPlan.viewTarget = TestFixtures.viewTarget(keys: ["id"])

        _ = try await DataWriteExecutor.run(viewPlan, commitMode: .automatic, on: driver(counting))

        #expect(counting.didCommit)
    }

    @Test("A keyed UPDATE through a view keeps the lenient rule: its count comes from the view's trigger")
    func keyedUpdateThroughAViewStaysLenient() async throws {
        let counting = CountingDriver(affectedRows: 0)
        var viewPlan = plan(expectedRowCount: 1, rowKind: .update, databaseType: .postgresql)
        viewPlan.viewTarget = TestFixtures.viewTarget(keys: ["id"])

        _ = try await DataWriteExecutor.run(viewPlan, commitMode: .automatic, on: driver(counting))

        #expect(counting.didCommit)
    }

    @Test("An UPDATE after a DELETE in the same save may find its row gone to the cascade, which is no failure")
    func updateAfterADeleteStaysLenient() async throws {
        let counting = CountingDriver(affectedRows: 0)
        let update = plan(expectedRowCount: 1, rowKind: .update, databaseType: .postgresql)
        let delete = DataWriteStep(
            kind: .rowWrite,
            statement: ParameterizedStatement(sql: "DELETE FROM \"t\" WHERE \"id\" = 1", parameters: []),
            expectedRowCount: 1,
            tableName: "t",
            rowKind: .delete
        )
        let cascading = DataWritePlan(scope: update.scope, databaseType: .postgresql, steps: [delete] + update.steps)

        _ = try await DataWriteExecutor.run(cascading, commitMode: .automatic, on: driver(counting))

        #expect(counting.didCommit)
    }

    @Test("A keyed DELETE that found its row already gone stays an ordinary save")
    func keyedDeleteOfAGoneRowIsNotAFailure() async throws {
        let counting = CountingDriver(affectedRows: 0)
        _ = try await DataWriteExecutor.run(
            plan(expectedRowCount: 1, rowKind: .delete, databaseType: .postgresql),
            commitMode: .automatic, on: driver(counting)
        )

        #expect(counting.didCommit)
    }

    @Test("A keyless write that found no row is rolled back rather than reported as a save")
    func keylessWriteThatMatchedNothingFails() async throws {
        let counting = CountingDriver(affectedRows: 0)
        await #expect(throws: DataWriteError.rowsNoLongerMatch(table: "t", expected: 1, actual: 0)) {
            try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, matchesRowsWithoutKey: true),
                commitMode: .automatic, on: driver(counting)
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
                commitMode: .automatic, on: driver(counting)
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
                commitMode: .automatic, on: driver(counting)
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
                commitMode: .automatic, on: driver(counting)
            )
        }
        #expect(counting.didRollBack)
    }

    @Test("An engine whose driver reports no real count is not held to one")
    func keylessWriteOnAnEngineWithoutCountsSucceeds() async throws {
        let counting = CountingDriver(affectedRows: 0)
        let results = try await DataWriteExecutor.run(
            plan(expectedRowCount: 1, matchesRowsWithoutKey: true, databaseType: .clickhouse),
            commitMode: .automatic, on: driver(counting)
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
            commitMode: .automatic, on: driver(counting)
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
                commitMode: .automatic, on: driver(counting)
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
            commitMode: .automatic, on: driver(counting)
        )

        #expect(!counting.trace.contains("open preserve"))
        #expect(counting.trace.contains("SET session_replication_role = origin"))
    }

    @Test("A plan without a prologue leaves the session's settings alone")
    func planWithoutPrologueOpensNoScope() async throws {
        let counting = CountingDriver(affectedRows: 1)
        _ = try await DataWriteExecutor.run(plan(expectedRowCount: 1), commitMode: .automatic, on: driver(counting))

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
            try await DataWriteExecutor.run(required, commitMode: .automatic, on: driver(counting))
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
            plan(expectedRowCount: 1, prologue: ["PRAGMA foreign_keys = OFF"]), commitMode: .automatic, on: driver(counting)
        )

        #expect(counting.didCommit)
    }

    @Test("The statements the run executed around the transaction are reported back")
    func sideStatementsAreReported() async throws {
        let counting = CountingDriver(affectedRows: 1)
        let run = try await DataWriteExecutor.run(
            plan(expectedRowCount: 1, prologue: ["A"], epilogue: ["B"]),
            commitMode: .automatic, on: driver(counting)
        )

        #expect(run.sideStatements == ["A", "B"])
    }

    @Test("Without transactions a failure halfway reports what already committed")
    func partialCommitCarriesTheCommittedResults() async throws {
        let counting = CountingDriver(affectedRows: 1, transactional: false, failOnStatement: 2)

        do {
            _ = try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, statementCount: 3), commitMode: .automatic, on: driver(counting)
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
                plan(expectedRowCount: 1, statementCount: 3), commitMode: .automatic, on: driver(counting)
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
                plan(expectedRowCount: 1, statementCount: 3), commitMode: .automatic, on: driver(counting)
            )
            Issue.record("expected the run to throw")
        } catch let error as DataWritePartialCommitError {
            #expect(error.committed.count == 1)
        }
    }

    @Test("A statement whose row count carries no meaning is not held to one")
    func unverifiedStepIsNotChecked() async throws {
        let counting = CountingDriver(affectedRows: 9_999)
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: nil), commitMode: .automatic, on: driver(counting)).results

        #expect(results.first?.wasVerified == false)
        #expect(counting.didCommit)
    }

    @Test(
        "A save joins a transaction the session already holds instead of committing it",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .holdsSessionLocks]
    )
    func saveJoinsTheSessionTransaction(state: PluginSessionTransactionState) async throws {
        let counting = CountingDriver(affectedRows: 1, sessionState: state)
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: 1), commitMode: .automatic, on: driver(counting)).results

        #expect(results.first?.rowsAffected == 1)
        #expect(counting.trace == ["UPDATE \"t\" SET \"b\" = 0"])
    }

    @Test("A session that reports nothing open is still wrapped, and so is one that cannot say")
    func saveWrapsWhenNothingIsOpen() async throws {
        for state in [PluginSessionTransactionState.idle, .unknown] {
            let counting = CountingDriver(affectedRows: 1, sessionState: state)
            _ = try await DataWriteExecutor.run(plan(expectedRowCount: 1), commitMode: .automatic, on: driver(counting))
            #expect(counting.trace.first == "BEGIN")
            #expect(counting.didCommit)
        }
    }

    @Test("A failure inside the user's transaction reports the statements as pending, not written")
    func failureInsideTheSessionTransactionIsPending() async throws {
        let counting = CountingDriver(affectedRows: 1, failOnStatement: 2, sessionState: .inTransaction)

        do {
            _ = try await DataWriteExecutor.run(
                plan(expectedRowCount: 1, statementCount: 3), commitMode: .automatic, on: driver(counting)
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
            try await DataWriteExecutor.run(plan(expectedRowCount: 1), commitMode: .automatic, on: driver(counting))
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
            for mode in ConnectionCommitMode.allCases {
                let owner = WriteTransactionOwner.resolve(supportsTransactions: false, sessionState: state, commitMode: mode)
                #expect(owner == WriteTransactionOwner.none)
                #expect(owner.sendsBegin == false)
                #expect(owner.canRollBack == false)
            }
        }
    }

    @Test(
        "A session holding a transaction or a lock owns it",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .holdsSessionLocks]
    )
    func sessionOwnsWhatItHolds(state: PluginSessionTransactionState) {
        for mode in ConnectionCommitMode.allCases {
            let owner = WriteTransactionOwner.resolve(supportsTransactions: true, sessionState: state, commitMode: mode)
            #expect(owner == .session)
            #expect(owner.sendsBegin == false)
            #expect(owner.canRollBack == false)
        }
    }

    @Test("The app owns the transaction when nothing is open, and when the driver cannot say")
    func appOwnsTheRest() {
        for state in [PluginSessionTransactionState.idle, .unknown] {
            let owner = WriteTransactionOwner.resolve(supportsTransactions: true, sessionState: state, commitMode: .automatic)
            #expect(owner == .app)
            #expect(owner.sendsBegin)
            #expect(owner.commitsAtEnd)
            #expect(owner.canRollBack)
        }
    }

    @Test("Manual Commit holds an idle session's write: BEGIN, no COMMIT, a rollback on failure")
    func manualCommitHoldsAnIdleSession() {
        let owner = WriteTransactionOwner.resolve(supportsTransactions: true, sessionState: .idle, commitMode: .manual)
        #expect(owner == .held)
        #expect(owner.sendsBegin)
        #expect(owner.commitsAtEnd == false)
        #expect(owner.canRollBack)
        #expect(WriteTransactionOwner.resolve(supportsTransactions: true, sessionState: .unknown, commitMode: .manual) == .app)
    }
}

struct DataWriteExecutorHeldTests {
    private func plan(prologue: [String] = []) -> DataWritePlan {
        DataWritePlan(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            databaseType: .sqlite,
            steps: [
                DataWriteStep(
                    kind: .rowWrite,
                    statement: ParameterizedStatement(sql: "UPDATE \"t\" SET \"b\" = 1", parameters: []),
                    expectedRowCount: 1,
                    tableName: "t"
                ),
            ],
            prologue: prologue
        )
    }

    private func driver(_ counting: CountingDriver) -> DatabaseDriver {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .sqlite), pluginDriver: counting)
    }

    @Test("A held save sends BEGIN and the write, and leaves the transaction open")
    func heldSaveLeavesTheTransactionOpen() async throws {
        let counting = CountingDriver(affectedRows: 1)
        _ = try await DataWriteExecutor.run(plan(), commitMode: .manual, on: driver(counting))
        #expect(counting.trace == ["BEGIN", "UPDATE \"t\" SET \"b\" = 1"])
    }

    @Test("A held save that fails rolls back the transaction it opened")
    func heldSaveRollsBackAFailure() async {
        let counting = CountingDriver(affectedRows: 1, failOnStatement: 1)
        await #expect(throws: (any Error).self) {
            try await DataWriteExecutor.run(plan(), commitMode: .manual, on: driver(counting))
        }
        #expect(counting.trace.first == "BEGIN")
        #expect(counting.didRollBack)
        #expect(counting.didCommit == false)
    }

    @Test("A save with session toggles is refused in Manual Commit before anything runs")
    func toggledSaveIsRefused() async {
        let counting = CountingDriver(affectedRows: 1)
        await #expect(throws: ManualCommitSessionOptionsRefusal()) {
            try await DataWriteExecutor.run(
                plan(prologue: ["PRAGMA foreign_keys = OFF"]), commitMode: .manual, on: driver(counting)
            )
        }
        #expect(counting.trace.isEmpty)
    }

    @Test(
        "A save the session can't hold is refused in Manual Commit before anything runs",
        arguments: [PluginSessionTransactionState.unknown, .holdsSessionLocks]
    )
    func unholdableSaveIsRefused(state: PluginSessionTransactionState) async {
        let counting = CountingDriver(affectedRows: 1, sessionState: state)
        await #expect(throws: ManualCommitRefusal()) {
            try await DataWriteExecutor.run(plan(), commitMode: .manual, on: driver(counting))
        }
        #expect(counting.trace.isEmpty)
    }

    @Test("A save on an engine without transactions is refused in Manual Commit")
    func saveWithoutTransactionsIsRefused() async {
        let counting = CountingDriver(affectedRows: 1, transactional: false)
        await #expect(throws: ManualCommitRefusal()) {
            try await DataWriteExecutor.run(plan(), commitMode: .manual, on: driver(counting))
        }
        #expect(counting.trace.isEmpty)
    }

    @Test("A held save marks the turn's hold, and a rolled-back one clears it")
    func heldSaveMarksTheTurn() async throws {
        let held = ManualCommitTurnHold()
        _ = try await ManualCommit.$turnHold.withValue(held) {
            try await DataWriteExecutor.run(plan(), commitMode: .manual, on: driver(CountingDriver(affectedRows: 1)))
        }
        #expect(held.isHeld)

        let failed = ManualCommitTurnHold()
        await ManualCommit.$turnHold.withValue(failed) {
            _ = try? await DataWriteExecutor.run(
                plan(), commitMode: .manual, on: driver(CountingDriver(affectedRows: 1, failOnStatement: 1))
            )
        }
        #expect(!failed.isHeld)
    }

    @Test("Manual Commit joins a transaction already open and sends no BEGIN")
    func heldSaveJoinsAnOpenTransaction() async throws {
        let counting = CountingDriver(affectedRows: 1, sessionState: .inTransaction)
        _ = try await DataWriteExecutor.run(plan(), commitMode: .manual, on: driver(counting))
        #expect(counting.trace == ["UPDATE \"t\" SET \"b\" = 1"])
    }
}
