//
//  CompareSyncExecutorBatchTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class BatchingSyncDriver: PluginDriverStub, @unchecked Sendable {
    struct Refused: Error {}

    var events: [String] = []
    var failing: Set<String> = []
    var rowsAffected = 1
    var stopsDuringBatch: Progress?

    var capabilities: PluginCapabilities { [.statementBatches] }
    var supportsTransactions: Bool { true }
    var supportsTransactionalDDL: Bool { true }

    func execute(query: String) async throws -> PluginQueryResult {
        events.append(query)
        if failing.contains(query) { throw Refused() }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: rowsAffected, executionTime: 0)
    }

    func executeStatements(_ statements: [PluginBatchStatement]) async throws -> [PluginBatchStatementOutcome]? {
        events.append("batch \(statements.map(\.query).joined(separator: " | "))")
        stopsDuringBatch?.cancel()
        var outcomes: [PluginBatchStatementOutcome] = []
        for statement in statements {
            if failing.contains(statement.query) { return outcomes + [.failed(Refused())] }
            outcomes.append(.succeeded(rowsAffected: rowsAffected, executionTime: 0))
        }
        return outcomes
    }

    func beginTransaction() async throws { events.append("begin") }
    func commitTransaction() async throws { events.append("commit") }
    func rollbackTransaction() async throws { events.append("rollback") }
}

struct CompareSyncExecutorBatchTests {
    private func run(
        _ statements: [SyncStatement],
        errorHandling: ImportErrorHandling = .stopAndRollback,
        mode: CompareSyncMode = .data,
        driver: BatchingSyncDriver,
        progress: Progress = Progress()
    ) async throws -> CompareSyncRunResult {
        var settings = CompareSyncExecutionSettings()
        settings.errorHandling = errorHandling
        return try await CompareSyncExecutor(gate: AlwaysAllowGate()).apply(
            statements: statements,
            mode: mode,
            settings: settings,
            target: DatabaseEndpoint(
                scope: DatabaseScope(connectionId: UUID(), database: "app", schema: "public"),
                connectionName: "staging",
                databaseType: .postgresql,
                safeModeLevel: .silent,
                color: .blue
            ),
            driver: driver,
            progress: progress
        )
    }

    private func statement(
        _ sql: String,
        expectedRowCount: Int? = nil,
        sessionEffect: SyncSessionEffect? = nil
    ) -> SyncStatement {
        SyncStatement(
            sql: sql, objectName: "t", summary: sql, expectedRowCount: expectedRowCount, sessionEffect: sessionEffect
        )
    }

    private static let inserts = (1...3).map { "INSERT INTO t VALUES (\($0))" }

    @Test("A run that rolls back on any failure sends its statements as one batch")
    func rollbackRunSendsOneBatch() async throws {
        let driver = BatchingSyncDriver()

        let result = try await run(Self.inserts.map { statement($0) }, driver: driver)

        #expect(driver.events == ["begin", "batch \(Self.inserts.joined(separator: " | "))", "commit"])
        #expect(result.executedCount == 3)
        #expect(!result.rolledBack)
    }

    @Test("A failure inside a batch is that statement's outcome, nothing after it is reported run, and the run rolls back")
    func failureInBatchStopsAndRollsBack() async throws {
        let driver = BatchingSyncDriver()
        driver.failing = [Self.inserts[1]]

        let result = try await run(Self.inserts.map { statement($0) }, driver: driver)

        #expect(result.outcomes.count == 2)
        #expect(result.outcomes[0].succeeded)
        #expect(result.outcomes[1].error != nil)
        #expect(!result.outcomes[1].didExecute)
        #expect(result.rolledBack)
        #expect(driver.events.last == "rollback")
    }

    @Test("A batched statement that changed more rows than expected fails as it ran, and the run rolls back")
    func overcountInBatchRollsBack() async throws {
        let driver = BatchingSyncDriver()
        driver.rowsAffected = 2

        let result = try await run(Self.inserts.map { statement($0, expectedRowCount: 1) }, driver: driver)

        #expect(result.outcomes.count == 1)
        #expect(result.outcomes[0].didExecute)
        #expect(result.outcomes[0].error != nil)
        #expect(result.rolledBack)
    }

    @Test("A Stop that lands while the last batch runs still rolls the run back")
    func stopDuringLastBatchRollsBack() async throws {
        let driver = BatchingSyncDriver()
        let progress = Progress()
        driver.stopsDuringBatch = progress

        let result = try await run(Self.inserts.map { statement($0) }, driver: driver, progress: progress)

        #expect(result.cancelled)
        #expect(result.rolledBack)
        #expect(driver.events.last == "rollback")
    }

    @Test("Stop and commit keeps every statement alone, since a count check does not end the transaction")
    func stopAndCommitRunsAlone() async throws {
        let driver = BatchingSyncDriver()

        _ = try await run(Self.inserts.map { statement($0) }, errorHandling: .stopAndCommit, driver: driver)

        #expect(driver.events == ["begin"] + Self.inserts + ["commit"])
    }

    @Test("A statement that opens a session scope runs alone between batches")
    func scopeStatementRunsAlone() async throws {
        let driver = BatchingSyncDriver()
        let scoped = statement(
            "SET session_replication_role = replica",
            sessionEffect: .opens(scope: "replica", closingSQL: "SET session_replication_role = DEFAULT")
        )
        let statements = [statement(Self.inserts[0]), statement(Self.inserts[1]), scoped, statement(Self.inserts[2])]

        _ = try await run(statements, driver: driver)

        #expect(driver.events == [
            "begin",
            "batch \(Self.inserts[0]) | \(Self.inserts[1])",
            "SET session_replication_role = replica",
            Self.inserts[2],
            "SET session_replication_role = DEFAULT",
            "commit",
        ])
    }
}
