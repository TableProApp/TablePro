//
//  StructureRebuildPartialFailureTests.swift
//  TableProTests
//
//  An engine whose DDL commits statement by statement keeps what ran before a failure, so the error names it.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class CommittingDDLDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    private var failuresLeft: [String: Int]
    let supportsTransactions: Bool
    private let state: PluginSessionTransactionState

    init(
        failing failuresLeft: [String: Int],
        supportsTransactions: Bool = false,
        state: PluginSessionTransactionState = .idle
    ) {
        self.failuresLeft = failuresLeft
        self.supportsTransactions = supportsTransactions
        self.state = state
    }

    var executed: [String] { lock.withLock { queries } }

    func sessionTransactionState() async -> PluginSessionTransactionState { state }

    func execute(query: String) async throws -> PluginQueryResult {
        let fails = lock.withLock { () -> Bool in
            queries.append(query)
            guard let left = failuresLeft[query], left > 0 else { return false }
            failuresLeft[query] = left - 1
            return true
        }
        if fails { throw DatabaseError.queryFailed("lost connection") }
        return .empty
    }

    func switchDatabase(to database: String) async throws {}
}

@MainActor
struct StructureRebuildPartialFailureTests {
    private func run(_ plan: PluginColumnReorderPlan, driver: CommittingDDLDriver) async -> String? {
        let connection = TestFixtures.makeConnection(database: "app")
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.status = .connected
        session.browseDatabase = "app"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let scope = DatabaseScope(connectionId: connection.id, database: "app", schema: nil)

        do {
            try await StructureRebuildPlanRunner.execute(
                StructureRebuildPlanRunner.Prepared(plan: plan, fingerprint: nil, scope: scope, tableName: "orders"),
                databaseType: connection.type,
                operationDescription: "Reorder Columns",
                isConfirmationPreCleared: true,
                gate: AlwaysAllowGate()
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test("A reorder that fails part way with nothing to undo it names the statements that stayed applied")
    func namesTheStatementsThatRan() async throws {
        let plan = PluginColumnReorderPlan(
            statements: ["MOVE a", "MOVE b", "MOVE c"],
            cost: .metadataOnly,
            verifications: []
        )
        let driver = CommittingDDLDriver(failing: ["MOVE b": 1])

        let message = try #require(await run(plan, driver: driver))

        #expect(message.contains("lost connection"))
        #expect(message.contains("MOVE a"))
        #expect(!message.contains("MOVE b"))
        #expect(!message.contains("MOVE c"))
        #expect(driver.executed == ["MOVE a", "MOVE b"])
    }

    @Test("A compensation that fails is named, so the hidden column can be restored by hand")
    func namesTheCompensationThatFailed() async throws {
        let plan = PluginColumnReorderPlan(
            statements: ["HIDE a", "SHOW a"],
            compensation: ["SHOW a"],
            cost: .metadataOnly,
            verifications: []
        )
        let driver = CommittingDDLDriver(failing: ["SHOW a": 2])

        let message = try #require(await run(plan, driver: driver))

        #expect(message.contains("lost connection"))
        #expect(message.contains("SHOW a"))
        #expect(!message.contains("HIDE a"))
        #expect(driver.executed == ["HIDE a", "SHOW a", "SHOW a"])
    }

    @Test("A compensation that puts everything back leaves only the failure in the message")
    func restoredPlanReportsTheFailureAlone() async throws {
        let plan = PluginColumnReorderPlan(
            statements: ["HIDE a", "SHOW a"],
            compensation: ["SHOW a"],
            cost: .metadataOnly,
            verifications: []
        )
        let driver = CommittingDDLDriver(failing: ["SHOW a": 1])

        let message = try #require(await run(plan, driver: driver))

        #expect(message == String(format: String(localized: "The change could not be applied: %@"), "lost connection"))
        #expect(driver.executed == ["HIDE a", "SHOW a", "SHOW a"])
    }

    @Test("A transactional plan that joined the user's open transaction says a rollback undoes what ran")
    func statementsInsideTheOpenTransactionAreNotCalledApplied() async throws {
        let plan = PluginColumnReorderPlan(
            statements: ["ALTER a", "ALTER b"],
            isTransactional: true,
            cost: .tableRebuild,
            verifications: []
        )
        let driver = CommittingDDLDriver(failing: ["ALTER b": 1], supportsTransactions: true, state: .inTransaction)

        let message = try #require(await run(plan, driver: driver))

        let pending = String(
            localized: "These statements ran inside the transaction already open on this connection, so rolling it back undoes them:"
        )
        #expect(message.contains(pending))
        #expect(!message.contains(String(localized: "These statements ran before the failure and were not rolled back:")))
        #expect(message.contains("ALTER a"))
        #expect(driver.executed == ["ALTER a", "ALTER b"])
    }

    @Test("A transactional plan on an engine without transactions names what ran as applied")
    func transactionalPlanWithoutTransactionsNamesWhatRan() async throws {
        let plan = PluginColumnReorderPlan(
            statements: ["ALTER a", "ALTER b"],
            isTransactional: true,
            cost: .tableRebuild,
            verifications: []
        )
        let driver = CommittingDDLDriver(failing: ["ALTER b": 1])

        let message = try #require(await run(plan, driver: driver))

        #expect(message.contains(String(localized: "These statements ran before the failure and were not rolled back:")))
        #expect(message.contains("ALTER a"))
    }

    @Test("A plan whose first statement fails names nothing as applied")
    func firstStatementFailureNamesNothing() async throws {
        let plan = PluginColumnReorderPlan(
            statements: ["MOVE a", "MOVE b"],
            cost: .metadataOnly,
            verifications: []
        )
        let driver = CommittingDDLDriver(failing: ["MOVE a": 1])

        let message = try #require(await run(plan, driver: driver))

        #expect(message == String(format: String(localized: "The change could not be applied: %@"), "lost connection"))
    }
}
