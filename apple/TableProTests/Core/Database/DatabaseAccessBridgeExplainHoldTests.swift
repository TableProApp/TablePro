//
//  DatabaseAccessBridgeExplainHoldTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class PlanningDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    private var state: PluginSessionTransactionState = .idle

    var statements: [String] { lock.withLock { sent } }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock {
            sent.append(query)
            switch query.uppercased() {
            case "BEGIN": state = .inTransaction
            case "COMMIT", "ROLLBACK": state = .idle
            default: break
            }
        }
        return .empty
    }

    func explainPlan(statement: String, variantId: String) async throws -> PluginQueryResult {
        lock.withLock { sent.append("PLAN \(variantId): \(statement)") }
        return .empty
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { lock.withLock { state } }

    func switchDatabase(to database: String) async throws {}
}

// An actual plan runs the statement, so an MCP explain_query in Manual Commit is held the way execute_query is.
@MainActor
struct DatabaseAccessBridgeExplainHoldTests {
    private static let update = "UPDATE t SET a = 1"

    private func seed() -> (connection: DatabaseConnection, driver: PlanningDriver) {
        var connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        connection.commitMode = .manual
        let driver = PlanningDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = "app"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func plan(_ connection: DatabaseConnection, runsStatement: Bool) async throws -> QueryResult {
        let scope = DatabaseScope(connectionId: connection.id, database: "app", schema: nil)
        let operation = try await ApprovedOperationFixture.approve(
            [OperationStatement(sql: Self.update)], scope: scope, databaseType: .postgresql
        )
        let outcome = try await DatabaseAccessBridge().runExplainPlan(
            operation,
            step: ExplainRequest.DriverStep(variantId: "actual", runsStatement: runsStatement),
            timeoutSeconds: 30,
            cancellation: nil
        )
        return outcome.result
    }

    @Test("A plan that runs a write in Manual Commit opens the transaction first and leaves it for the user")
    func runningPlanIsHeld() async throws {
        let (connection, driver) = seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let result = try await plan(connection, runsStatement: true)

        let begin = try #require(driver.statements.firstIndex(of: "BEGIN"))
        let plan = try #require(driver.statements.firstIndex(of: "PLAN actual: \(Self.update)"))
        #expect(begin < plan)
        #expect(!driver.statements.contains("COMMIT"))
        #expect(result.statusMessage?.contains(ManualCommit.pendingNotice) == true)
    }

    @Test("A plan that only plans the write opens no transaction")
    func plannedOnlyIsNotHeld() async throws {
        let (connection, driver) = seed()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let result = try await plan(connection, runsStatement: false)

        #expect(driver.statements.contains("PLAN actual: \(Self.update)"))
        #expect(!driver.statements.contains("BEGIN"))
        #expect(result.statusMessage == nil)
    }
}
