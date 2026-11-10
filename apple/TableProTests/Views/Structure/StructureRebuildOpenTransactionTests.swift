//
//  StructureRebuildOpenTransactionTests.swift
//  TableProTests
//
//  Inside an open transaction SQLite ignores PRAGMA foreign_keys = off, so a rebuild there cascades into child rows.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class RebuildSessionDriver: PluginDriverStub, @unchecked Sendable {
    private let state: PluginSessionTransactionState
    private let lock = NSLock()
    private var queries: [String] = []

    init(state: PluginSessionTransactionState) {
        self.state = state
    }

    var executed: [String] { lock.withLock { queries } }
    var supportsTransactions: Bool { true }

    func sessionTransactionState() async -> PluginSessionTransactionState { state }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { queries.append(query) }
        return .empty
    }

    func switchDatabase(to database: String) async throws {}
}

@MainActor
struct StructureRebuildOpenTransactionTests {
    private static let plan = PluginColumnReorderPlan(
        statements: ["DROP TABLE parent"],
        prologue: ["PRAGMA foreign_keys = off"],
        epilogue: ["PRAGMA foreign_keys = on"],
        isTransactional: true,
        cost: .tableRebuild,
        verifications: []
    )

    private func run(state: PluginSessionTransactionState) async throws -> [String] {
        let connection = TestFixtures.makeConnection(database: "app")
        let driver = RebuildSessionDriver(state: state)
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
                StructureRebuildPlanRunner.Prepared(plan: Self.plan, fingerprint: nil, scope: scope, tableName: "parent"),
                databaseType: connection.type,
                operationDescription: "Apply Schema Changes",
                isConfirmationPreCleared: true,
                gate: AlwaysAllowGate()
            )
        } catch StructureRebuildPlanRunner.RunError.sessionTransactionOpen {
            return driver.executed + ["refused"]
        }
        return driver.executed
    }

    @Test("A rebuild that turns foreign keys off refuses to run inside the user's open transaction")
    func refusesInsideAnOpenTransaction() async throws {
        let executed = try await run(state: .inTransaction)

        #expect(executed == ["refused"])
    }

    @Test("With no transaction open the rebuild turns foreign keys off before its own BEGIN")
    func runsOutsideATransaction() async throws {
        let executed = try await run(state: .idle)

        #expect(executed == [
            "PRAGMA foreign_keys = off", "BEGIN", "DROP TABLE parent", "COMMIT", "PRAGMA foreign_keys = on"
        ])
    }
}
