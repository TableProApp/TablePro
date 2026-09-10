//
//  DataWriteExecutorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

/// One test double for every case in this file: it records the order of everything it was asked to
/// do, reports whatever affected-row count the test wants, and can be told to fail on the Nth
/// statement.
private final class CountingDriver: PluginDatabaseDriver, @unchecked Sendable {
    struct Failure: Error {}

    let affectedRows: Int
    let transactional: Bool
    /// One-based index of the statement that should throw, counting only the ones the plan runs.
    let failOnStatement: Int?
    let rollbackFails: Bool

    /// Every call in the order it arrived: statement text, plus "BEGIN", "COMMIT" and "ROLLBACK".
    private(set) var trace: [String] = []
    private var statementCount = 0

    var executed: [String] { trace.filter { !["BEGIN", "COMMIT", "ROLLBACK"].contains($0) } }
    var didCommit: Bool { trace.contains("COMMIT") }
    var didRollBack: Bool { trace.contains("ROLLBACK") }

    init(
        affectedRows: Int,
        transactional: Bool = true,
        failOnStatement: Int? = nil,
        rollbackFails: Bool = false
    ) {
        self.affectedRows = affectedRows
        self.transactional = transactional
        self.failOnStatement = failOnStatement
        self.rollbackFails = rollbackFails
    }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { transactional }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        trace.append(query)
        statementCount += 1
        if let failOnStatement, statementCount == failOnStatement { throw Failure() }
        return PluginQueryResult(
            columns: [], columnTypeNames: [], rows: [], rowsAffected: affectedRows, executionTime: 0
        )
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws { trace.append("BEGIN") }
    func commitTransaction() async throws { trace.append("COMMIT") }
    func rollbackTransaction() async throws {
        trace.append("ROLLBACK")
        if rollbackFails { throw Failure() }
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

@Suite("Data write execution")
struct DataWriteExecutorTests {
    private func plan(
        expectedRowCount: Int?,
        statementCount: Int = 1,
        prologue: [String] = [],
        epilogue: [String] = []
    ) -> DataWritePlan {
        DataWritePlan(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            databaseType: .sqlite,
            steps: (0 ..< statementCount).map { index in
                DataWriteStep(
                    kind: .rowWrite,
                    statement: ParameterizedStatement(sql: "UPDATE \"t\" SET \"b\" = \(index)", parameters: []),
                    expectedRowCount: expectedRowCount,
                    tableName: "t"
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

    @Test("The foreign-key disable runs before the transaction, and the re-enable after it")
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
            "PRAGMA foreign_keys = OFF",
            "BEGIN",
            "UPDATE \"t\" SET \"b\" = 0",
            "COMMIT",
            "PRAGMA foreign_keys = ON",
        ])
    }

    @Test("Foreign keys are re-enabled after a rollback too")
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

        #expect(counting.didRollBack)
        #expect(counting.trace.last == "PRAGMA foreign_keys = ON")
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
}
