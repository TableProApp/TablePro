//
//  ImportDataSinkAdapterRollbackTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

/// Holds a transaction the way MySQL does: open from `BEGIN`, or from any statement under `autocommit = 0`, until a
/// `COMMIT`, a `ROLLBACK` other than to a savepoint or, unless DDL is transactional as on PostgreSQL, a `CREATE`,
/// `ALTER` or `DROP`, which commits even when it then fails. It reports the state from its last success, as an error
/// packet carries no status flags, unless `refreshesAfterError` reads it again after a failure.
private final class StatusFlagDriver: PluginDriverStub, @unchecked Sendable {
    static let failingInsert = "INSERT INTO courses (start_date) VALUES ('0000-00-00')"

    let supportsTransactionalDDL: Bool
    private let reportsState: Bool
    private let autocommits: Bool
    private let refreshesAfterError: Bool
    private let failureEndsTransaction: Bool
    private let failingStatements: Set<String>
    private var isInTransaction = false
    private var reportsInTransaction = false
    private(set) var executed: [String] = []
    private(set) var stateReads = 0
    var tableEngine: String?
    var hasTransactions = true
    var insertHold: AsyncGate?
    var commitHold: AsyncGate?

    init(
        reportsState: Bool = true,
        transactionalDDL: Bool = false,
        autocommits: Bool = true,
        refreshesAfterError: Bool = false,
        failureEndsTransaction: Bool = false,
        failingStatements: Set<String> = [StatusFlagDriver.failingInsert]
    ) {
        self.reportsState = reportsState
        self.supportsTransactionalDDL = transactionalDDL
        self.autocommits = autocommits
        self.refreshesAfterError = refreshesAfterError
        self.failureEndsTransaction = failureEndsTransaction
        self.failingStatements = failingStatements
    }

    func execute(query: String) async throws -> PluginQueryResult {
        executed.append(query)
        if query.hasPrefix("INSERT"), let insertHold { await insertHold.wait() }
        if query == "COMMIT", let commitHold { await commitHold.wait() }
        let head = query.split(separator: " ").first.map { $0.uppercased() } ?? ""
        let isDDL = ["CREATE", "ALTER", "DROP"].contains(head)
        if isDDL, !supportsTransactionalDDL { isInTransaction = false }
        if failingStatements.contains(query) {
            if failureEndsTransaction { isInTransaction = false }
            if refreshesAfterError { reportsInTransaction = isInTransaction }
            throw DatabaseError.queryFailed("statement refused")
        }
        switch head {
        case "BEGIN":
            isInTransaction = true
        case "COMMIT", "ROLLBACK":
            if !query.uppercased().hasPrefix("ROLLBACK TO") { isInTransaction = false }
        default:
            if !isDDL, !autocommits { isInTransaction = true }
        }
        reportsInTransaction = isInTransaction
        return .empty
    }

    var supportsTransactions: Bool { hasTransactions }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: tableEngine)
    }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        stateReads += 1
        guard reportsState else { return .unknown }
        return reportsInTransaction ? .inTransaction : .idle
    }
}

/// "Stop and Rollback" promised a rollback that MySQL had already made impossible: the dump's first `DROP TABLE`
/// committed the import's transaction, every statement after it autocommitted, and the `ROLLBACK` took nothing back.
struct ImportDataSinkAdapterRollbackTests {
    private func makeSink(on driver: StatusFlagDriver) -> (ImportDataSinkAdapter, PluginDriverAdapter) {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        return (ImportDataSinkAdapter(driver: adapter, databaseType: .mysql), adapter)
    }

    private func runUntilFailure(
        _ statements: [String],
        failingAt failing: String = StatusFlagDriver.failingInsert,
        on sink: ImportDataSinkAdapter
    ) async throws {
        try await sink.beginTransaction()
        for statement in statements {
            try await sink.execute(statement: statement, line: 1)
        }
        await #expect(throws: DatabaseError.self) {
            try await sink.execute(statement: failing, line: 1)
        }
    }

    /// One file of several runs inside the run's transaction. On an engine that cannot report its session, a `BEGIN`
    /// of the file's own would open a second one, and MySQL commits the run's on it.
    @Test("A sink that joins a run's transaction sends no BEGIN, COMMIT or ROLLBACK")
    func joinedSinkSendsNoTransactionStatements() async throws {
        let driver = StatusFlagDriver(reportsState: false)
        let connection = TestFixtures.makeConnection(type: .mysql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        let sink = ImportDataSinkAdapter(driver: adapter, databaseType: .mysql, joinsTransaction: true)

        try await sink.beginTransaction()
        try await sink.execute(statement: "INSERT INTO courses VALUES (1)", line: 1)
        try await sink.commitTransaction()
        try await sink.rollbackTransaction()

        #expect(driver.executed == ["INSERT INTO courses VALUES (1)"])
        #expect(sink.transactionOutcome == .untracked)
    }

    @Test("A transaction a DROP already committed is not rolled back, and the sink says so")
    func committedTransactionIsNotRolledBack() async throws {
        let driver = StatusFlagDriver()
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(
            ["DROP TABLE IF EXISTS courses", "CREATE TABLE courses (start_date DATE)", "INSERT INTO courses VALUES (NULL)"],
            on: sink
        )
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .committedBeforeRollback)
        #expect(!driver.executed.contains("ROLLBACK"))
    }

    @Test("The import no longer owns a transaction it found committed")
    func committedTransactionIsReleased() async throws {
        let driver = StatusFlagDriver()
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(["DROP TABLE IF EXISTS courses"], on: sink)
        try await sink.rollbackTransaction()
        try await sink.rollbackTransaction()
        try await sink.commitTransaction()

        #expect(driver.executed == ["BEGIN", "DROP TABLE IF EXISTS courses", StatusFlagDriver.failingInsert])
    }

    /// Under `autocommit = 0` the statement after the DROP opens a new transaction, so at the rollback the session
    /// reads as in one again, and only the statements after the DROP are rolled back.
    @Test("A commit in the middle is still recorded when a new transaction is open by the rollback")
    func commitBeforeAReopenedTransactionIsRecorded() async throws {
        let driver = StatusFlagDriver(autocommits: false)
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(
            ["INSERT INTO courses VALUES (1)", "DROP TABLE IF EXISTS lessons", "INSERT INTO courses VALUES (2)"],
            on: sink
        )
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .committedBeforeRollback)
        #expect(driver.executed.last == "ROLLBACK")
    }

    /// MySQL commits before it runs a DDL statement, so one that then fails has ended the transaction, but the session
    /// reads the same as after a deadlock, so the sink names no commit.
    @Test("A failing DDL statement that ended the transaction is reported as ended by the server")
    func failingDDLEndIsNotCalledACommit() async throws {
        let failingCreate = "CREATE TABLE courses (start_date DATE DEFAULT '0000-00-00')"
        let driver = StatusFlagDriver(refreshesAfterError: true, failingStatements: [failingCreate])
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(["INSERT INTO lessons VALUES (1)"], failingAt: failingCreate, on: sink)
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .endedByServer)
        #expect(!driver.executed.contains("ROLLBACK"))
    }

    /// A deadlock rolls the whole transaction back on the server. Calling that a commit would tell the user rows were
    /// kept that are gone.
    @Test("A transaction a deadlock ended is not reported as committed")
    func deadlockIsNotCalledACommit() async throws {
        let driver = StatusFlagDriver(refreshesAfterError: true, failureEndsTransaction: true)
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(["INSERT INTO courses VALUES (1)", "INSERT INTO courses VALUES (2)"], on: sink)
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .endedByServer)
        #expect(!driver.executed.contains("ROLLBACK"))
    }

    @Test("A transaction still open is rolled back as before")
    func openTransactionIsRolledBack() async throws {
        let driver = StatusFlagDriver()
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(["INSERT INTO courses VALUES (NULL)"], on: sink)
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .rolledBack)
        #expect(driver.executed.last == "ROLLBACK")
    }

    @Test("A driver that cannot tell rolls back as before")
    func unknownStateRollsBack() async throws {
        let driver = StatusFlagDriver(reportsState: false)
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(["DROP TABLE IF EXISTS courses"], on: sink)
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .rolledBack)
        #expect(driver.executed.last == "ROLLBACK")
    }

    @Test("An engine that rolls DDL back rolls a DROP back with the rest")
    func transactionalDDLIsRolledBack() async throws {
        let driver = StatusFlagDriver(transactionalDDL: true)
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(["DROP TABLE IF EXISTS courses"], on: sink)
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .rolledBack)
        #expect(driver.executed.last == "ROLLBACK")
    }

    /// The file's own `COMMIT` ends the import's transaction on PostgreSQL too, and a Stop's `ROLLBACK` then undoes
    /// nothing, so calling it a rollback told the user rows were gone that are still there.
    @Test("A file's own COMMIT on an engine that rolls DDL back is reported as a commit, not a rollback")
    func fileCommitOnTransactionalDDLEngine() async throws {
        let driver = StatusFlagDriver(transactionalDDL: true)
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(["INSERT INTO courses VALUES (1)", "COMMIT"], on: sink)
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .committedBeforeRollback)
        #expect(!driver.executed.contains("ROLLBACK"))
    }

    /// The file's second transaction is open by the Stop, so its `ROLLBACK` undoes that one only. The session reads
    /// the same as if the first had never committed.
    @Test("A file's own COMMIT and BEGIN on an engine that rolls DDL back still count as a commit")
    func fileCommitThenBeginOnTransactionalDDLEngine() async throws {
        let driver = StatusFlagDriver(transactionalDDL: true)
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(
            ["INSERT INTO courses VALUES (1)", "COMMIT", "BEGIN", "INSERT INTO courses VALUES (2)"],
            on: sink
        )
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .committedBeforeRollback)
        #expect(driver.executed.last == "ROLLBACK")
    }

    /// MySQL reads idle after the file's own `ROLLBACK` exactly as after a DDL's commit, so the text decides.
    @Test("A file's own ROLLBACK is not called a commit")
    func fileRollbackIsNotCalledACommit() async throws {
        let driver = StatusFlagDriver()
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(["INSERT INTO courses VALUES (1)", "ROLLBACK"], on: sink)
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .endedByFile)
        #expect(driver.executed.filter { $0 == "ROLLBACK" }.count == 1)
    }

    @Test("A ROLLBACK TO SAVEPOINT in the file leaves the import's transaction to roll back")
    func rollbackToSavepointChangesNothing() async throws {
        let driver = StatusFlagDriver()
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(
            ["SAVEPOINT before_courses", "INSERT INTO courses VALUES (1)", "ROLLBACK TO SAVEPOINT before_courses"],
            on: sink
        )
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .rolledBack)
        #expect(driver.executed.last == "ROLLBACK")
    }

    @Test("A transaction the server ended on an engine that rolls DDL back is not called a commit")
    func serverEndedTransactionOnTransactionalDDLEngine() async throws {
        let driver = StatusFlagDriver(transactionalDDL: true, refreshesAfterError: true, failureEndsTransaction: true)
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(["DROP TABLE IF EXISTS courses"], on: sink)
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .endedByServer)
        #expect(!driver.executed.contains("ROLLBACK"))
    }

    /// SQL Server reads its transaction state with a query, so reading it after every statement would double an
    /// import's round trips. Only an engine whose DDL commits needs the read.
    @Test("An engine that rolls DDL back is asked its state at the begin and the rollback only")
    func transactionalDDLEngineReadsNoStatePerStatement() async throws {
        let driver = StatusFlagDriver(transactionalDDL: true)
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(
            ["INSERT INTO courses VALUES (1)", "INSERT INTO courses VALUES (2)", "INSERT INTO courses VALUES (3)"],
            on: sink
        )
        try await sink.rollbackTransaction()

        #expect(driver.stateReads == 2)
    }

    @Test("An engine whose DDL commits is asked its state after every statement that succeeds")
    func implicitCommitEngineReadsStatePerStatement() async throws {
        let driver = StatusFlagDriver()
        let (sink, _) = makeSink(on: driver)

        try await runUntilFailure(
            ["INSERT INTO courses VALUES (1)", "INSERT INTO courses VALUES (2)", "INSERT INTO courses VALUES (3)"],
            on: sink
        )
        try await sink.rollbackTransaction()

        #expect(driver.stateReads == 5)
    }

    @Test("A transaction the user opened is neither rolled back nor reported")
    func usersTransactionIsLeftAlone() async throws {
        let driver = StatusFlagDriver()
        let (sink, adapter) = makeSink(on: driver)
        _ = try await adapter.execute(query: "BEGIN")

        try await runUntilFailure(["DROP TABLE IF EXISTS courses"], on: sink)
        try await sink.rollbackTransaction()

        #expect(sink.transactionOutcome == .untracked)
        #expect(!driver.executed.contains("ROLLBACK"))
        #expect(driver.executed.filter { $0 == "BEGIN" }.count == 1)
    }

    @Test("An import that commits reports a commit, even after a DDL statement committed part of it")
    func commitIsReported() async throws {
        let driver = StatusFlagDriver()
        let (sink, _) = makeSink(on: driver)

        try await sink.beginTransaction()
        try await sink.execute(statement: "DROP TABLE IF EXISTS courses", line: 1)
        try await sink.execute(statement: "INSERT INTO lessons VALUES (1)", line: 2)
        try await sink.commitTransaction()

        #expect(sink.transactionOutcome == .committed)
    }
}

private final class StopOutcomeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func bump() { lock.withLock { value += 1 } }
}

// A Stop promised a rollback only where one is certain: the import's own transaction, on tables that roll back.
struct ImportStopRollbackTests {
    private func makeRowSink(
        on driver: StatusFlagDriver,
        targetRollback: ImportTargetRollback,
        changes: StopOutcomeCount = StopOutcomeCount()
    ) -> (ImportDataSinkAdapter, PluginDriverAdapter) {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        let sink = ImportDataSinkAdapter(
            driver: adapter,
            databaseType: .mysql,
            targetTable: "courses",
            targetRollback: targetRollback,
            onStopOutcomeChange: { changes.bump() }
        )
        return (sink, adapter)
    }

    @Test("The import's own transaction on tables that roll back promises the rollback, and keeps it")
    func ownTransactionRollsBack() async throws {
        let driver = StatusFlagDriver()
        let changes = StopOutcomeCount()
        let (sink, _) = makeRowSink(on: driver, targetRollback: .rollsBack, changes: changes)
        #expect(!sink.rollsBackOnStop)

        try await sink.beginTransaction()
        #expect(sink.rollsBackOnStop)
        #expect(changes.count == 1)

        try await sink.rollbackTransaction()
        #expect(!sink.rollsBackOnStop)
        #expect(sink.transactionOutcome == .rolledBack)
        #expect(driver.executed.contains("ROLLBACK"))
    }

    @Test("A statement that commits the transaction takes the promise back")
    func earlyCommitEndsThePromise() async throws {
        let driver = StatusFlagDriver()
        let changes = StopOutcomeCount()
        let (sink, _) = makeRowSink(on: driver, targetRollback: .rollsBack, changes: changes)

        try await sink.beginTransaction()
        try await sink.execute(statement: "CREATE TABLE extra (id INT)", line: 1)

        #expect(!sink.rollsBackOnStop)
        #expect(changes.count == 2)
    }

    @Test("A Stop during the last row write rolls back where the row runner would have committed")
    func stopDuringLastRowWriteRollsBack() async throws {
        let driver = StatusFlagDriver(failingStatements: [])
        let hold = AsyncGate()
        driver.insertHold = hold
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .mysql), pluginDriver: driver)
        let progress = PluginImportProgress(progress: Progress(totalUnitCount: 0))
        let sink = ImportDataSinkAdapter(
            driver: adapter,
            databaseType: .mysql,
            targetTable: "courses",
            columnMapping: ["id": "id"],
            sourceFields: ["id"],
            targetRollback: .rollsBack,
            refusesCommitAfterStop: true,
            isCancelled: { progress.isCancelled }
        )
        let run = Task {
            var batches: [[RowImportRunner.Entry]] = [[(line: 2, row: ["id": .text("1")])]]
            return try await RowImportRunner.run(
                configuration: RowImportRunner.Configuration(
                    errorHandling: .stopAndRollback, wrapInTransaction: true, deleteExistingRows: false
                ),
                sink: sink,
                progress: progress
            ) { batches.isEmpty ? nil : batches.removeFirst() }
        }
        await hold.arrived(1)
        #expect(sink.rollsBackOnStop)
        progress.cancel()
        await hold.open()

        await #expect(throws: PluginImportCancellationError.self) { _ = try await run.value }
        #expect(driver.executed.contains("ROLLBACK"))
        #expect(!driver.executed.contains("COMMIT"))
        #expect(sink.transactionOutcome == .rolledBack)
    }

    @Test("Once the commit is on its way the Stop no longer promises a rollback")
    func committingEndsThePromise() async throws {
        let driver = StatusFlagDriver()
        let hold = AsyncGate()
        driver.commitHold = hold
        let (sink, _) = makeRowSink(on: driver, targetRollback: .rollsBack)
        try await sink.beginTransaction()

        let commit = Task { try await sink.commitTransaction() }
        await hold.arrived(1)
        #expect(!sink.rollsBackOnStop)
        await hold.open()
        try await commit.value

        #expect(sink.transactionOutcome == .committed)
    }

    @Test("A table that keeps its rows through a ROLLBACK is never promised one, and a rollback reads as kept")
    func nonTransactionalTableKeepsRows() async throws {
        let driver = StatusFlagDriver()
        let (sink, _) = makeRowSink(on: driver, targetRollback: .keepsRows)

        try await sink.beginTransaction()
        #expect(!sink.rollsBackOnStop)

        try await sink.rollbackTransaction()
        #expect(sink.transactionOutcome == .untracked)
    }

    @Test("Rows written inside the user's own transaction are not promised a rollback and read as still open")
    func usersTransactionIsNotPromised() async throws {
        let driver = StatusFlagDriver()
        let (sink, adapter) = makeRowSink(on: driver, targetRollback: .rollsBack)
        _ = try await adapter.execute(query: "BEGIN")

        try await sink.beginTransaction()
        #expect(!sink.rollsBackOnStop)

        try await sink.rollbackTransaction()
        #expect(!driver.executed.contains("ROLLBACK"))
        #expect(sink.transactionOutcome == .joinedUserTransaction)
    }

    @Test("An engine without transactions is never promised a rollback")
    func engineWithoutTransactions() async throws {
        let driver = StatusFlagDriver()
        driver.hasTransactions = false
        let (sink, _) = makeRowSink(on: driver, targetRollback: .rollsBack)

        try await sink.beginTransaction()

        #expect(!sink.rollsBackOnStop)
        #expect(!driver.executed.contains("BEGIN"))
    }

    @Test("A file of unknown reach is never promised a rollback")
    func unknownReachIsNotPromised() async throws {
        let driver = StatusFlagDriver()
        let (sink, _) = makeRowSink(on: driver, targetRollback: .unknown)

        try await sink.beginTransaction()

        #expect(!sink.rollsBackOnStop)
    }

    @Test("MySQL reads the target's engine: InnoDB rolls back, MyISAM keeps its rows, no engine is unknown")
    func mysqlTargetEngine() async {
        let driver = StatusFlagDriver()
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .mysql), pluginDriver: driver)

        driver.tableEngine = "InnoDB"
        #expect(await ImportService.targetRollback(of: "courses", schema: nil, on: adapter) == .rollsBack)
        driver.tableEngine = "MyISAM"
        #expect(await ImportService.targetRollback(of: "courses", schema: nil, on: adapter) == .keepsRows)
        driver.tableEngine = nil
        #expect(await ImportService.targetRollback(of: "courses", schema: nil, on: adapter) == .unknown)
    }

    @Test("A SQL file rolls back only where DDL does and no table engine decides")
    func sqlFileReach() async {
        let mysql = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .mysql),
            pluginDriver: StatusFlagDriver(transactionalDDL: true)
        )
        let postgres = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .postgresql),
            pluginDriver: StatusFlagDriver(transactionalDDL: true)
        )
        let oracleLike = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .postgresql),
            pluginDriver: StatusFlagDriver(transactionalDDL: false)
        )

        #expect(await ImportService.targetRollback(of: nil, schema: nil, on: mysql) == .unknown)
        #expect(await ImportService.targetRollback(of: nil, schema: nil, on: postgres) == .rollsBack)
        #expect(await ImportService.targetRollback(of: nil, schema: nil, on: oracleLike) == .unknown)
        #expect(await ImportService.targetRollback(of: "orders", schema: nil, on: postgres) == .rollsBack)
    }

    @Test("Several files roll back only when every target does")
    func batchCombination() {
        #expect(ImportService.combined([.rollsBack, .rollsBack]) == .rollsBack)
        #expect(ImportService.combined([.rollsBack, .unknown]) == .unknown)
        #expect(ImportService.combined([.unknown, .keepsRows, .rollsBack]) == .keepsRows)
    }
}
