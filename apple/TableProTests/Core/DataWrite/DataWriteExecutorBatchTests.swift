//
//  DataWriteExecutorBatchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class BatchingDriver: PluginDriverStub, @unchecked Sendable {
    struct Failure: Error {}

    let affectedRows: Int
    let failOnStatement: Int?
    let sessionState: PluginSessionTransactionState
    let declinesBatches: Bool
    private(set) var trace: [String] = []
    private var statementCount = 0

    init(
        affectedRows: Int = 1,
        failOnStatement: Int? = nil,
        sessionState: PluginSessionTransactionState = .idle,
        declinesBatches: Bool = false
    ) {
        self.affectedRows = affectedRows
        self.failOnStatement = failOnStatement
        self.sessionState = sessionState
        self.declinesBatches = declinesBatches
    }

    var capabilities: PluginCapabilities { [.statementBatches] }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        trace.append(query)
        statementCount += 1
        if statementCount == failOnStatement { throw Failure() }
        let rows: [[PluginCellValue]] = query.hasPrefix("SELECT") ? [[.text("1")]] : []
        return PluginQueryResult(
            columns: rows.isEmpty ? [] : ["id"], columnTypeNames: rows.isEmpty ? [] : ["int4"], rows: rows,
            rowsAffected: affectedRows, executionTime: 0
        )
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    func executeStatements(_ statements: [PluginBatchStatement]) async throws -> [PluginBatchStatementOutcome]? {
        guard !declinesBatches else { return nil }
        trace.append("BATCH \(statements.count)")
        var outcomes: [PluginBatchStatementOutcome] = []
        for _ in statements {
            statementCount += 1
            if statementCount == failOnStatement {
                outcomes.append(.failed(Failure()))
                return outcomes
            }
            outcomes.append(.succeeded(rowsAffected: affectedRows, executionTime: 0))
        }
        return outcomes
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { sessionState }
    func beginTransaction(mode: PluginTransactionAccessMode) async throws { trace.append("BEGIN") }
    func commitTransaction() async throws { trace.append("COMMIT") }
    func rollbackTransaction() async throws { trace.append("ROLLBACK") }
}

struct DataWriteExecutorBatchTests {
    private static let statements = (0..<3).map { "UPDATE \"t\" SET \"b\" = \($0)" }

    private func plan(expectedRowCount: Int? = 1, lookupOnFirst: Bool = false) -> DataWritePlan {
        DataWritePlan(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            databaseType: .postgresql,
            steps: Self.statements.enumerated().map { index, sql in
                DataWriteStep(
                    kind: .rowWrite,
                    statement: ParameterizedStatement(sql: sql, parameters: [index]),
                    expectedRowCount: expectedRowCount,
                    tableName: "t",
                    rowKind: .update,
                    lookup: lookupOnFirst && index == 0
                        ? RowLookup(query: ParameterizedStatement(sql: "SELECT 1", parameters: []), rowCount: 1, pinsRows: false)
                        : nil
                )
            }
        )
    }

    private func run(
        _ plan: DataWritePlan,
        on batching: BatchingDriver,
        commitMode: ConnectionCommitMode = .automatic
    ) async throws -> DataWriteRun {
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: batching)
        return try await DataWriteExecutor.run(plan, commitMode: commitMode, on: driver)
    }

    @Test("A save the app's own transaction holds goes out as one batch, each statement still held to its count")
    func appTransactionSendsOneBatch() async throws {
        let batching = BatchingDriver()

        let results = try await run(plan(), on: batching).results

        #expect(batching.trace == ["BEGIN", "BATCH 3", "COMMIT"])
        #expect(results.map(\.rowsAffected) == [1, 1, 1])
        #expect(results.allSatisfy { $0.wasVerified })
    }

    @Test("A statement in a batch that matched too many rows rolls the whole save back")
    func tooManyRowsInBatchRollsBack() async throws {
        let batching = BatchingDriver(affectedRows: 2)

        await #expect(throws: DataWriteError.tooManyRowsAffected(table: "t", expected: 1, actual: 2)) {
            try await run(plan(), on: batching)
        }
        #expect(batching.trace == ["BEGIN", "BATCH 3", "ROLLBACK"])
    }

    @Test("A statement that fails in a batch surfaces its own error and rolls back")
    func failureInBatchRollsBack() async throws {
        let batching = BatchingDriver(failOnStatement: 2)

        await #expect(throws: BatchingDriver.Failure.self) {
            try await run(plan(), on: batching)
        }
        #expect(batching.trace == ["BEGIN", "BATCH 3", "ROLLBACK"])
    }

    @Test("Manual Commit's held transaction rolls a failure back, so its save is one batch too")
    func heldTransactionSendsOneBatch() async throws {
        let batching = BatchingDriver()

        _ = try await run(plan(), on: batching, commitMode: .manual)

        #expect(batching.trace == ["BEGIN", "BATCH 3"])
    }

    @Test("Inside the user's own transaction each statement goes alone, so none runs past a refused one")
    func userTransactionSendsAlone() async throws {
        let batching = BatchingDriver(affectedRows: 2, sessionState: .inTransaction)

        await #expect(throws: DataWriteError.tooManyRowsAffectedInSessionTransaction(table: "t", expected: 1, actual: 2)) {
            try await run(plan(), on: batching)
        }
        #expect(batching.trace == [Self.statements[0]])
    }

    @Test("A step that looks its row up keeps the whole save one statement at a time")
    func lookupSendsAlone() async throws {
        let batching = BatchingDriver()

        _ = try await run(plan(lookupOnFirst: true), on: batching)

        #expect(!batching.trace.contains { $0.hasPrefix("BATCH") })
        #expect(batching.trace.filter { Self.statements.contains($0) } == Self.statements)
    }

    @Test("A driver that declines the batch gets each statement alone, in order")
    func declinedBatchRunsAlone() async throws {
        let batching = BatchingDriver(declinesBatches: true)

        let results = try await run(plan(), on: batching).results

        #expect(batching.trace == ["BEGIN"] + Self.statements + ["COMMIT"])
        #expect(results.count == 3)
    }
}
