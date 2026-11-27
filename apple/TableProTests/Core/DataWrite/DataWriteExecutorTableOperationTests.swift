//
//  DataWriteExecutorTableOperationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class TableOperationDriver: PluginDriverStub, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private let state: PluginSessionTransactionState
    private let failing: String?
    private var sent: [String] = []

    init(state: PluginSessionTransactionState = .idle, failing: String? = nil) {
        self.state = state
        self.failing = failing
    }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var trace: [String] { lock.withLock { sent } }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { sent.append(query) }
        if query == failing { throw Failure() }
        return .empty
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { state }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws { lock.withLock { sent.append("BEGIN") } }
    func commitTransaction() async throws { lock.withLock { sent.append("COMMIT") } }
    func rollbackTransaction() async throws { lock.withLock { sent.append("ROLLBACK") } }

    func switchDatabase(to database: String) async throws {}
}

struct DataWriteExecutorTableOperationTests {
    private static let dropA = "DROP TABLE a"
    private static let dropB = "DROP TABLE b"

    private static let truncateA = "DELETE FROM a ALL"

    private static func dropPlan(_ databaseType: DatabaseType) -> DataWritePlan {
        tableOperationPlan([dropA, dropB], databaseType: databaseType)
    }

    private static func tableOperationPlan(_ statements: [String], databaseType: DatabaseType = .teradata) -> DataWritePlan {
        DataWritePlan(
            scope: DatabaseScope(connectionId: UUID(), database: "sales", schema: nil),
            databaseType: databaseType,
            steps: statements.map {
                DataWriteStep(kind: .tableOperation, statement: ParameterizedStatement(sql: $0, parameters: []))
            }
        )
    }

    private static func adapter(_ driver: TableOperationDriver, type: DatabaseType) -> DatabaseDriver {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: type), pluginDriver: driver)
    }

    @Test("Two Teradata drops each end their own transaction, with no commit after the last")
    func teradataDropsCommitOneByOne() async throws {
        let driver = TableOperationDriver()

        let run = try await DataWriteExecutor.run(
            Self.dropPlan(.teradata), commitMode: .automatic, on: Self.adapter(driver, type: .teradata)
        )

        #expect(run.results.count == 2)
        #expect(driver.trace == ["BEGIN", Self.dropA, "COMMIT", "BEGIN", Self.dropB, "COMMIT"])
    }

    @Test("Drops on an engine without the rule keep one transaction")
    func otherEnginesKeepOneTransaction() async throws {
        let driver = TableOperationDriver()

        _ = try await DataWriteExecutor.run(
            Self.dropPlan(.mysql), commitMode: .automatic, on: Self.adapter(driver, type: .mysql)
        )

        #expect(driver.trace == ["BEGIN", Self.dropA, Self.dropB, "COMMIT"])
    }

    @Test("Teradata drops are refused before anything runs while the session holds a transaction")
    func teradataDropsRefusedInsideAnOpenTransaction() async throws {
        let driver = TableOperationDriver(state: .inTransaction)

        await #expect(throws: DefinitionInOpenTransactionRefusal()) {
            try await DataWriteExecutor.run(
                Self.dropPlan(.teradata), commitMode: .automatic, on: Self.adapter(driver, type: .teradata)
            )
        }
        #expect(driver.trace.isEmpty)
    }

    @Test("Teradata drops are refused before anything runs under Manual Commit")
    func teradataDropsRefusedUnderManualCommit() async throws {
        let driver = TableOperationDriver()

        await #expect(throws: ManualCommitRefusal()) {
            try await DataWriteExecutor.run(
                Self.dropPlan(.teradata), commitMode: .manual, on: Self.adapter(driver, type: .teradata)
            )
        }
        #expect(driver.trace.isEmpty)
    }

    @Test("A Teradata drop that fails after another committed reports that one as written")
    func failedSecondDropReportsTheFirstAsWritten() async throws {
        let driver = TableOperationDriver(failing: Self.dropB)

        do {
            _ = try await DataWriteExecutor.run(
                Self.dropPlan(.teradata), commitMode: .automatic, on: Self.adapter(driver, type: .teradata)
            )
            Issue.record("The save reported success")
        } catch let partial as DataWritePartialCommitError {
            #expect(partial.committed.count == 1)
            #expect(partial.totalStatements == 2)
            #expect(partial.disposition == .written)
        }
        #expect(driver.trace == ["BEGIN", Self.dropA, "COMMIT", "BEGIN", Self.dropB, "ROLLBACK"])
    }

    @Test("A Teradata truncate joins the drop's transaction, which the drop then ends")
    func teradataTruncateJoinsTheDropsSegment() async throws {
        let driver = TableOperationDriver()

        _ = try await DataWriteExecutor.run(
            Self.tableOperationPlan([Self.truncateA, Self.dropB]), commitMode: .automatic,
            on: Self.adapter(driver, type: .teradata)
        )

        #expect(driver.trace == ["BEGIN", Self.truncateA, Self.dropB, "COMMIT"])
    }

    @Test("A Teradata truncate after a drop runs in a transaction of its own, committed at the end")
    func teradataTruncateAfterADropGetsTheFinalCommit() async throws {
        let driver = TableOperationDriver()

        _ = try await DataWriteExecutor.run(
            Self.tableOperationPlan([Self.dropB, Self.truncateA]), commitMode: .automatic,
            on: Self.adapter(driver, type: .teradata)
        )

        #expect(driver.trace == ["BEGIN", Self.dropB, "COMMIT", "BEGIN", Self.truncateA, "COMMIT"])
    }

    @Test("A Teradata truncate alone is held under Manual Commit and joins an open session transaction")
    func teradataTruncateAloneIsDML() async throws {
        let held = TableOperationDriver()
        _ = try await DataWriteExecutor.run(
            Self.tableOperationPlan([Self.truncateA]), commitMode: .manual, on: Self.adapter(held, type: .teradata)
        )
        #expect(held.trace == ["BEGIN", Self.truncateA])

        let joined = TableOperationDriver(state: .inTransaction)
        _ = try await DataWriteExecutor.run(
            Self.tableOperationPlan([Self.truncateA]), commitMode: .automatic, on: Self.adapter(joined, type: .teradata)
        )
        #expect(joined.trace == [Self.truncateA])
    }
}
