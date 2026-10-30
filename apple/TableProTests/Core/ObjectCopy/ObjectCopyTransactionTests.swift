//
//  ObjectCopyTransactionTests.swift
//  TableProTests
//
//  The copy runs against a driver `withMetadataDriver` hands it, which is the connection's own
//  session driver on every engine that opts out of pooling (DuckDB, PGlite). A `BEGIN` of its own
//  over a transaction the user already had open aborts it on DuckDB and commits their pending work
//  on the engines that commit implicitly, so the copy joins the session's transaction instead, the
//  way `DataWriteExecutor`, `DatabaseManager+Principals` and `StructureRebuildPlanRunner` do.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct StatementFailure: Error {}

private final class CopyEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var events: [String] { lock.withLock { entries } }

    func record(_ event: String) {
        lock.withLock { entries.append(event) }
    }
}

private final class RecordingCopyDriver: PluginDriverStub, @unchecked Sendable {
    private let name: String
    private let log: CopyEventLog
    private let sessionState: PluginSessionTransactionState
    private let failing: Set<String>
    private let failsInserts: Bool
    private let failsInsertsAfter: Int?
    private let cancelsOnInsert: Bool
    private let rowCount: Int
    private let transactional: Bool
    private let brokenRows: Int
    private let throwsCancellationAfter: Int?
    private var inserts = 0

    init(
        _ name: String,
        log: CopyEventLog,
        sessionState: PluginSessionTransactionState = .idle,
        failing: Set<String> = [],
        failsInserts: Bool = false,
        failsInsertsAfter: Int? = nil,
        cancelsOnInsert: Bool = false,
        rowCount: Int = 1,
        transactional: Bool = true,
        brokenRows: Int = 0,
        throwsCancellationAfter: Int? = nil
    ) {
        self.name = name
        self.log = log
        self.sessionState = sessionState
        self.failing = failing
        self.failsInserts = failsInserts
        self.failsInsertsAfter = failsInsertsAfter
        self.cancelsOnInsert = cancelsOnInsert
        self.rowCount = rowCount
        self.transactional = transactional
        self.brokenRows = brokenRows
        self.throwsCancellationAfter = throwsCancellationAfter
    }

    var capabilities: PluginCapabilities { [] }
    var supportsTransactions: Bool { transactional }
    var supportsTransactionalDDL: Bool { transactional }

    private func record(_ event: String) {
        log.record("\(name) \(event)")
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { sessionState }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        record("open \(purpose)")
        guard purpose == .relaxedForeignKeys else { return nil }
        return PluginSessionScope(purpose: purpose, saved: [], applied: [])
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        record(Task.isCancelled ? "close \(scope.purpose) while cancelled" : "close \(scope.purpose)")
    }

    func execute(query: String) async throws -> PluginQueryResult {
        record(query)
        if failing.contains(query) { throw StatementFailure() }
        if query.hasPrefix("SELECT COUNT(*)") {
            return PluginQueryResult(
                columns: ["count"], columnTypeNames: [], rows: [[.text("\(brokenRows)")]], rowsAffected: 0, executionTime: 0
            )
        }
        return PluginQueryResult(
            columns: ["id"],
            columnTypeNames: [],
            rows: Array(repeating: [.text("1")], count: rowCount),
            rowsAffected: rowCount,
            executionTime: 0
        )
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        record("insert")
        if cancelsOnInsert {
            withUnsafeCurrentTask { task in
                guard let task else { return }
                task.cancel()
            }
        }
        inserts += 1
        if inserts > throwsCancellationAfter ?? .max { throw CancellationError() }
        if failsInserts || inserts > failsInsertsAfter ?? .max { throw StatementFailure() }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 1, executionTime: 0)
    }

    func beginTransaction() async throws { record("begin") }
    func commitTransaction() async throws { record("commit") }
    func rollbackTransaction() async throws { record("rollback") }
}

@MainActor
private final class StubMetadataProvider: ScopedMetadataProviding {
    private let drivers: [UUID: DatabaseDriver]
    private let leases: CopyEventLog?

    init(leases: CopyEventLog? = nil, drivers: [UUID: DatabaseDriver]) {
        self.drivers = drivers
        self.leases = leases
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let driver = drivers[scope.connectionId] else {
            throw ObjectCopyError.refused("No driver for \(scope.connectionId)")
        }
        leases?.record("lease \(scope.database)")
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

@MainActor
struct ObjectCopyTransactionTests {
    private let sourceScope = DatabaseScope(connectionId: UUID(), database: "app", schema: nil)
    private let targetScope = DatabaseScope(connectionId: UUID(), database: "staging", schema: nil)

    // Different engines, so the copier opens no scope of its own and the log holds only the runner's.
    private let sourceType = DatabaseType.postgresql
    private let targetType = DatabaseType.mysql

    private func endpoint(_ scope: DatabaseScope, _ type: DatabaseType) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: scope,
            connectionName: scope.database,
            databaseType: type,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    private func request(
        _ selections: [ObjectCopySelection],
        content: ObjectCopyContent,
        errorHandling: ImportErrorHandling = .stopAndRollback
    ) -> ObjectCopyRequest {
        ObjectCopyRequest(
            source: endpoint(sourceScope, sourceType),
            destination: .existing(endpoint(targetScope, targetType)),
            objects: selections,
            content: content,
            existingPolicy: .replace,
            errorHandling: errorHandling,
            wrapEachTableInTransaction: true
        )
    }

    private func dataStep(
        _ table: String, clears: Bool = false, keyChecks: [ObjectCopyKeyCheck] = [], rollsBack: Bool = true
    ) -> ObjectCopyTableStep {
        ObjectCopyTableStep(
            selection: ObjectCopySelection(kind: .table, name: table, schema: nil),
            dropStatements: [],
            sequenceStatements: [],
            createStatements: [],
            truncateStatements: clears
                ? [SyncStatement(sql: "DELETE FROM \(table)", objectName: table, summary: "clear")]
                : [],
            columns: ["id"],
            primaryKeyColumns: ["id"],
            sourceQuery: "SELECT id FROM \(table)",
            targetTable: table,
            targetSchema: nil,
            estimatedRows: nil,
            copiesData: true,
            copiesIdentityColumn: false,
            note: nil,
            keyChecks: keyChecks,
            rollsBack: rollsBack
        )
    }

    private func dataPlan(
        _ steps: [ObjectCopyTableStep],
        errorHandling: ImportErrorHandling = .stopAndRollback,
        keysInside: Bool = true
    ) -> ObjectCopyPlan {
        ObjectCopyPlan(
            request: request(steps.map(\.selection), content: .data, errorHandling: errorHandling),
            createsDatabase: false,
            tableSteps: steps,
            definitionSteps: [],
            keysInside: ObjectCopyKeysInside(created: keysInside, rows: keysInside)
        )
    }

    /// A replacement: the drop and the create are one unit, which is what makes the structure phase
    /// want a transaction of its own.
    private func replacementPlan(errorHandling: ImportErrorHandling = .stopAndRollback) -> ObjectCopyPlan {
        let selection = ObjectCopySelection(kind: .table, name: "orders", schema: nil)
        let step = ObjectCopyTableStep(
            selection: selection,
            dropStatements: [SyncStatement(sql: "DROP TABLE orders;", objectName: "orders", summary: "drop")],
            sequenceStatements: [],
            createStatements: [
                SyncStatement(sql: "CREATE TABLE orders (id INTEGER);", objectName: "orders", summary: "create"),
            ],
            truncateStatements: [],
            columns: [],
            primaryKeyColumns: ["id"],
            sourceQuery: "SELECT id FROM orders",
            targetTable: "orders",
            targetSchema: nil,
            estimatedRows: nil,
            copiesData: false,
            copiesIdentityColumn: false,
            note: nil
        )
        return ObjectCopyPlan(
            request: request([selection], content: .structure, errorHandling: errorHandling),
            createsDatabase: false,
            tableSteps: [step],
            definitionSteps: []
        )
    }

    private func run(
        _ plan: ObjectCopyPlan,
        source: RecordingCopyDriver,
        target: RecordingCopyDriver,
        leases: CopyEventLog? = nil
    ) async throws -> ObjectCopyRunResult {
        let provider = StubMetadataProvider(leases: leases, drivers: [
            sourceScope.connectionId: PluginDriverAdapter(
                connection: TestFixtures.makeConnection(type: sourceType), pluginDriver: source
            ),
            targetScope.connectionId: PluginDriverAdapter(
                connection: TestFixtures.makeConnection(type: targetType), pluginDriver: target
            ),
        ])
        let runner = ObjectCopyRunner(manager: provider, gate: AlwaysAllowGate())
        return try await runner.run(plan, progress: ObjectCopyProgress(progress: Progress()))
    }

    // MARK: - Structure

    @Test("An idle session lets the copy open its own transaction")
    func idleSessionKeepsTheCopysOwnTransaction() async throws {
        let log = CopyEventLog()

        let result = try await run(
            replacementPlan(), source: RecordingCopyDriver("source", log: log), target: RecordingCopyDriver("target", log: log)
        )

        #expect(log.events == [
            "target begin", "target DROP TABLE orders;", "target CREATE TABLE orders (id INTEGER);", "target commit",
        ])
        #expect(result.pendingInSessionTransaction == false)
    }

    /// The statements still run: they join the transaction the user opened, and only the user can
    /// end it. Opening one over it is what aborted it on DuckDB.
    @Test("A session holding a transaction is joined rather than wrapped, with its keys as they are")
    func openSessionTransactionIsJoined() async throws {
        let log = CopyEventLog()
        let target = RecordingCopyDriver("target", log: log, sessionState: .inTransaction)

        let result = try await run(replacementPlan(), source: RecordingCopyDriver("source", log: log), target: target)

        #expect(log.events == ["target DROP TABLE orders;", "target CREATE TABLE orders (id INTEGER);"])
        #expect(result.pendingInSessionTransaction)
    }

    /// A `LOCK TABLES` holds no transaction to commit, but a `START TRANSACTION` would release it,
    /// so the copy sends none.
    @Test("A session holding locks is joined too")
    func sessionLocksAreJoined() async throws {
        let log = CopyEventLog()
        let target = RecordingCopyDriver("target", log: log, sessionState: .holdsSessionLocks)

        let result = try await run(replacementPlan(), source: RecordingCopyDriver("source", log: log), target: target)

        #expect(!log.events.contains("target begin"))
        #expect(result.pendingInSessionTransaction)
    }

    /// PostgreSQL commits an aborted transaction as a ROLLBACK, so a run that keeps going past a
    /// failure would report tables that were never created.
    @Test(
        "Only a run that promises a rollback puts the structure in a transaction",
        arguments: [ImportErrorHandling.skipAndContinue, .stopAndCommit]
    )
    func structureWithoutRollbackHasNoTransaction(errorHandling: ImportErrorHandling) async throws {
        let log = CopyEventLog()

        _ = try await run(
            replacementPlan(errorHandling: errorHandling),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log)
        )

        #expect(log.events == [
            "target open relaxedForeignKeys",
            "target DROP TABLE orders;",
            "target CREATE TABLE orders (id INTEGER);",
            "target close relaxedForeignKeys",
        ])
    }

    /// MySQL refuses a CREATE whose key names a missing table only while the checks are on.
    @Test("A new table relaxes the target's checks only when its keys stay inside the copy", arguments: [true, false])
    func creationRelaxesOnlyInsideTheCopy(keysInside: Bool) async throws {
        let log = CopyEventLog()
        let base = replacementPlan(errorHandling: .stopAndCommit)
        let created = base.tableSteps.map { step in
            ObjectCopyTableStep(
                selection: step.selection,
                dropStatements: [],
                sequenceStatements: [],
                createStatements: step.createStatements,
                truncateStatements: [],
                columns: [],
                primaryKeyColumns: step.primaryKeyColumns,
                sourceQuery: step.sourceQuery,
                targetTable: step.targetTable,
                targetSchema: nil,
                estimatedRows: nil,
                copiesData: false,
                copiesIdentityColumn: false,
                note: nil
            )
        }
        let plan = ObjectCopyPlan(
            request: base.request,
            createsDatabase: false,
            tableSteps: created,
            definitionSteps: [],
            keysInside: ObjectCopyKeysInside(created: keysInside)
        )

        _ = try await run(plan, source: RecordingCopyDriver("source", log: log), target: RecordingCopyDriver("target", log: log))

        let create = "target CREATE TABLE orders (id INTEGER);"
        #expect(log.events == (keysInside
            ? ["target open relaxedForeignKeys", create, "target close relaxedForeignKeys"]
            : [create]))
    }

    @Test("A schema that cannot be created rolls the structure transaction back before the lease returns")
    func failedSchemaRollsBack() async throws {
        let log = CopyEventLog()
        let createSchema = "CREATE SCHEMA staging"
        let base = replacementPlan()
        let plan = ObjectCopyPlan(
            request: base.request,
            createsDatabase: false,
            tableSteps: base.tableSteps,
            definitionSteps: [],
            schemaStatements: [SyncStatement(sql: createSchema, objectName: "staging", summary: "schema")]
        )

        await #expect(throws: (any Error).self) {
            _ = try await run(
                plan,
                source: RecordingCopyDriver("source", log: log),
                target: RecordingCopyDriver("target", log: log, failing: [createSchema])
            )
        }

        #expect(log.events == ["target begin", "target \(createSchema)", "target rollback"])
    }

    // MARK: - Rows

    @Test("Rows are written with the target's keys relaxed inside its transaction, and the source left alone")
    func rowsAreRelaxedOnTheTargetInsideItsTransaction() async throws {
        let log = CopyEventLog()

        let result = try await run(
            dataPlan([dataStep("buildings")]),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log)
        )

        #expect(result.rowsCopied == 1)
        #expect(log.events == [
            "target begin",
            "target open relaxedForeignKeys",
            "source SELECT id FROM buildings",
            "target insert",
            "target close relaxedForeignKeys",
            "target commit",
        ])
    }

    /// Turning the checks back on checks nothing already written, so a child copied without its
    /// parent's rows would keep pointing at nothing.
    @Test("Rows whose keys point outside the copy keep the target's checks on")
    func keysOutsideTheCopyKeepTheChecks() async throws {
        let log = CopyEventLog()

        _ = try await run(
            dataPlan([dataStep("buildings")], keysInside: false),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log)
        )

        #expect(log.events == [
            "target begin", "source SELECT id FROM buildings", "target insert", "target commit",
        ])
    }

    /// Committed table by table, a cycle's first table kept rows pointing at a second that then failed.
    @Test("Stop and roll back writes every table's rows in one transaction")
    func rollbackRunsTheRowsInOneTransaction() async throws {
        let log = CopyEventLog()

        let result = try await run(
            dataPlan([dataStep("estates"), dataStep("buildings")]),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log)
        )

        #expect(result.rowsCopied == 2)
        #expect(log.events == [
            "target begin",
            "target open relaxedForeignKeys",
            "source SELECT id FROM estates",
            "target insert",
            "source SELECT id FROM buildings",
            "target insert",
            "target close relaxedForeignKeys",
            "target commit",
        ])
    }

    /// PostgreSQL commits an aborted transaction as a ROLLBACK, so a table wrapped in one lost
    /// every batch written ahead of its failure.
    @Test("Stop and keep what ran commits each batch with the checks on, and counts what a failure kept")
    func stopAndKeepCommitsEachBatch() async throws {
        let log = CopyEventLog()

        let result = try await run(
            dataPlan([dataStep("buildings")], errorHandling: .stopAndCommit),
            source: RecordingCopyDriver("source", log: log, rowCount: SQLWriteBatchBudget.maximumRows + 1),
            target: RecordingCopyDriver("target", log: log, failsInsertsAfter: 1)
        )

        #expect(result.rowsCopied == SQLWriteBatchBudget.maximumRows)
        #expect(result.failures.map { $0.outcome.rowsCopied } == [SQLWriteBatchBudget.maximumRows])
        #expect(log.events == ["source SELECT id FROM buildings", "target insert", "target insert"])
    }

    @Test("A rolled back table reports none of the batches it wrote before failing")
    func rolledBackFailureCountsNothing() async throws {
        let log = CopyEventLog()

        let result = try await run(
            dataPlan([dataStep("buildings")]),
            source: RecordingCopyDriver("source", log: log, rowCount: SQLWriteBatchBudget.maximumRows + 1),
            target: RecordingCopyDriver("target", log: log, failsInsertsAfter: 1)
        )

        #expect(result.rowsCopied == 0)
        #expect(result.failures.map { $0.outcome.rowsCopied } == [0])
        #expect(log.events.last == "target rollback")
    }

    /// Nothing can be taken back there, so leaving the rows out of the count would send a retry over them.
    @Test("A target with no transactions counts what a stopped or failed table wrote")
    func untransactionalTargetCountsWhatItKept() async throws {
        let log = CopyEventLog()

        let stopped = try await Task {
            try await run(
                dataPlan([dataStep("buildings")]),
                source: RecordingCopyDriver("source", log: log),
                target: RecordingCopyDriver("target", log: log, cancelsOnInsert: true, transactional: false)
            )
        }.value
        let failed = try await run(
            dataPlan([dataStep("buildings")]),
            source: RecordingCopyDriver("source", log: log, rowCount: SQLWriteBatchBudget.maximumRows + 1),
            target: RecordingCopyDriver("target", log: log, failsInsertsAfter: 1, transactional: false)
        )

        #expect(stopped.cancelled)
        #expect(stopped.rowsCopied == 1)
        #expect(failed.rowsCopied == SQLWriteBatchBudget.maximumRows)
        #expect(!log.events.contains("target begin"))
        #expect(!log.events.contains("target open relaxedForeignKeys"))
    }

    @Test("A relaxed copy checks every key it wrote before it commits")
    func relaxedCopyChecksKeysBeforeCommit() async throws {
        let log = CopyEventLog()
        let check = ObjectCopyKeyCheck(constraint: "fk_estate", sql: "SELECT COUNT(*) FROM buildings")

        let result = try await run(
            dataPlan([dataStep("buildings", keyChecks: [check])]),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log)
        )

        #expect(result.rowsCopied == 1)
        #expect(log.events == [
            "target begin",
            "target SELECT COUNT(*) FROM buildings",
            "target open relaxedForeignKeys",
            "source SELECT id FROM buildings",
            "target insert",
            "target SELECT COUNT(*) FROM buildings",
            "target close relaxedForeignKeys",
            "target commit",
        ])
    }

    /// A write-only login copies parents first with the checks on, as it did before they could be relaxed.
    @Test("A key the account cannot check keeps the target's checks on")
    func uncheckableKeyKeepsTheChecks() async throws {
        let log = CopyEventLog()
        let check = ObjectCopyKeyCheck(constraint: "fk_estate", sql: "SELECT COUNT(*) FROM buildings")

        let result = try await run(
            dataPlan([dataStep("buildings", keyChecks: [check])]),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log, failing: [check.sql])
        )

        #expect(result.rowsCopied == 1)
        #expect(log.events == [
            "target begin",
            "target SELECT COUNT(*) FROM buildings",
            "source SELECT id FROM buildings",
            "target insert",
            "target commit",
        ])
    }

    /// A child read after its parent while the source was changing, or one the source already broke.
    @Test("A row a key refuses fails the copy and takes every table back")
    func brokenKeyRollsTheCopyBack() async throws {
        let log = CopyEventLog()
        let check = ObjectCopyKeyCheck(constraint: "fk_estate", sql: "SELECT COUNT(*) FROM buildings")

        let result = try await run(
            dataPlan([dataStep("estates"), dataStep("buildings", keyChecks: [check])]),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log, brokenRows: 2)
        )

        #expect(result.rowsCopied == 0)
        #expect(result.failures.map { $0.outcome.selection.name } == ["buildings"])
        #expect(log.events.suffix(2) == ["target close relaxedForeignKeys", "target rollback"])
    }

    /// MySQL keeps a MyISAM table's rows through a ROLLBACK.
    @Test("A table the target keeps through a rollback still reports its rows")
    func tableThatCannotRollBackKeepsItsCount() async throws {
        let log = CopyEventLog()

        let result = try await run(
            dataPlan([dataStep("audit", rollsBack: false), dataStep("buildings")]),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log, failsInsertsAfter: 1)
        )

        #expect(log.events.last == "target rollback")
        #expect(result.rowsCopied == 1)
        #expect(result.outcomes.map { "\($0.selection.name) \($0.rowsCopied) \($0.error == nil)" } == [
            "audit 1 true", "buildings 0 false",
        ])
    }

    @Test(
        "Both paths lease the target before the source",
        arguments: [ImportErrorHandling.stopAndRollback, .stopAndCommit]
    )
    func leasesTheTargetFirst(errorHandling: ImportErrorHandling) async throws {
        let log = CopyEventLog()
        let leases = CopyEventLog()

        _ = try await run(
            dataPlan([dataStep("buildings")], errorHandling: errorHandling),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log),
            leases: leases
        )

        #expect(leases.events == ["lease staging", "lease app"])
    }

    @Test("A driver that throws a cancellation keeps the count of the batches before it")
    func thrownCancellationKeepsTheCount() async throws {
        let log = CopyEventLog()

        let result = try await run(
            dataPlan([dataStep("buildings")], errorHandling: .stopAndCommit),
            source: RecordingCopyDriver("source", log: log, rowCount: SQLWriteBatchBudget.maximumRows + 1),
            target: RecordingCopyDriver("target", log: log, throwsCancellationAfter: 1)
        )

        #expect(result.cancelled)
        #expect(result.rowsCopied == SQLWriteBatchBudget.maximumRows)
    }

    /// Relaxed, a DELETE would leave rows in a table outside the copy pointing at nothing.
    @Test("Clears run with the target's keys on, before the rows relax them")
    func clearsRunWithKeysOn() async throws {
        let log = CopyEventLog()

        _ = try await run(
            dataPlan([dataStep("buildings", clears: true)]),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log)
        )

        #expect(log.events == [
            "target begin",
            "target DELETE FROM buildings",
            "target open relaxedForeignKeys",
            "source SELECT id FROM buildings",
            "target insert",
            "target close relaxedForeignKeys",
            "target commit",
        ])
    }

    @Test("A copy that throws puts the target's keys back before rolling back")
    func failedCopyRestoresKeys() async throws {
        let log = CopyEventLog()

        let result = try await run(
            dataPlan([dataStep("buildings")]),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log, failsInserts: true)
        )

        #expect(result.failedCount == 1)
        #expect(log.events == [
            "target begin",
            "target open relaxedForeignKeys",
            "source SELECT id FROM buildings",
            "target insert",
            "target close relaxedForeignKeys",
            "target rollback",
        ])
    }

    @Test("A stopped copy puts the target's keys back outside the cancellation")
    func cancelledCopyRestoresKeys() async throws {
        let log = CopyEventLog()
        let plan = dataPlan([dataStep("buildings")])
        let source = RecordingCopyDriver("source", log: log)
        let target = RecordingCopyDriver("target", log: log, cancelsOnInsert: true)

        let result = try await Task { try await run(plan, source: source, target: target) }.value

        #expect(result.cancelled)
        #expect(log.events == [
            "target begin",
            "target open relaxedForeignKeys",
            "source SELECT id FROM buildings",
            "target insert",
            "target close relaxedForeignKeys",
            "target rollback",
        ])
    }

    @Test("Rows joining the session's own transaction keep its keys as they are")
    func sessionTransactionIsNotRelaxed() async throws {
        let log = CopyEventLog()

        let result = try await run(
            dataPlan([dataStep("buildings")]),
            source: RecordingCopyDriver("source", log: log),
            target: RecordingCopyDriver("target", log: log, sessionState: .inTransaction)
        )

        #expect(result.pendingInSessionTransaction)
        #expect(log.events == ["source SELECT id FROM buildings", "target insert"])
    }

    /// The table still holds its own rows, so the source's would be appended beside them. Past that
    /// failure the rows keep the target's keys, since a child's parent rows can be missing.
    @Test("Under Skip and continue a table whose clear failed gets no rows, and none are relaxed")
    func failedClearGetsNoRows() async throws {
        let log = CopyEventLog()
        let target = RecordingCopyDriver("target", log: log, failing: ["DELETE FROM buildings"])

        let result = try await run(
            dataPlan(
                [dataStep("estates", clears: true), dataStep("buildings", clears: true)],
                errorHandling: .skipAndContinue
            ),
            source: RecordingCopyDriver("source", log: log),
            target: target
        )

        #expect(result.failures.map { $0.outcome.selection.name } == ["buildings"])
        #expect(result.rowsCopied == 1)
        #expect(log.events == [
            "target DELETE FROM buildings",
            "target DELETE FROM estates",
            "source SELECT id FROM estates",
            "target insert",
        ])
    }
}
