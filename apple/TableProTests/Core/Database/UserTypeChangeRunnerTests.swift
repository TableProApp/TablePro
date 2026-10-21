//
//  UserTypeChangeRunnerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct RefusedStatement: LocalizedError {
    let errorDescription: String?
}

private final class TypeEditStubDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    let refusing: String?
    let transactionalDDL: Bool
    let addsLabelsOutsideTransaction: Bool

    init(refusing: String? = nil, transactionalDDL: Bool = true, addsLabelsOutsideTransaction: Bool = false) {
        self.refusing = refusing
        self.transactionalDDL = transactionalDDL
        self.addsLabelsOutsideTransaction = addsLabelsOutsideTransaction
    }

    func userDefinedTypeChangeRunsOutsideTransaction(_ change: PluginUserDefinedTypeChange) -> Bool {
        guard case .addEnumLabel = change else { return false }
        return addsLabelsOutsideTransaction
    }

    var executed: [String] { lock.withLock { queries } }

    var supportsTransactionalDDL: Bool { transactionalDDL }

    func execute(query: String) async throws -> PluginQueryResult {
        if let refusing, query.contains(refusing) {
            throw RefusedStatement(errorDescription: "column \"v\" of table \"t\" contains values that violate the new constraint")
        }
        lock.withLock { queries.append(query) }
        return .empty
    }

    func alterUserDefinedTypeStatements(type: PluginUserDefinedTypeInfo, change: PluginUserDefinedTypeChange) -> [String]? {
        switch change {
        case .addEnumLabel(let label, _): ["ALTER TYPE \(type.name) ADD VALUE '\(label)'"]
        case .addCheck(let check, _): ["ALTER DOMAIN \(type.name) ADD CHECK (\(check.expression))"]
        case .setNotNull(let value): ["ALTER DOMAIN \(type.name) \(value ? "SET" : "DROP") NOT NULL"]
        case .rename(let name): ["ALTER DOMAIN \(type.name) RENAME TO \(name)"]
        default: nil
        }
    }
}

@MainActor
struct UserTypeChangeRunnerTests {
    private let domain = UserDefinedTypeInfo(name: "posint", kind: .domain, schema: "app")
    private let mood = UserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "app")

    private func install(_ pooled: TypeEditStubDriver) async throws -> (DatabaseConnection, DatabaseScope) {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        DatabaseManager.shared.injectSession(
            ConnectionSession(
                connection: connection,
                driver: PluginDriverAdapter(connection: connection, pluginDriver: TypeEditStubDriver())
            ),
            for: connection.id
        )
        let scope = DatabaseScope(connectionId: connection.id, database: "app", schema: "app")
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pooled)
        try await adapter.connect()
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)
        return (connection, scope)
    }

    private func uninstall(_ connection: DatabaseConnection) {
        MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func plan(_ type: UserDefinedTypeInfo, _ changes: [StagedTypeChange], driver: TypeEditStubDriver) throws -> UserTypeChangePlan {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        return try UserTypeChangePlan.build(
            type: type,
            changes: changes,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
    }

    @Test("Every step runs in one transaction on the save's own connection")
    func appliesInATransaction() async throws {
        let pooled = TypeEditStubDriver()
        let (connection, scope) = try await install(pooled)
        defer { uninstall(connection) }
        let changes = [
            StagedTypeChange(change: .setNotNull(true)),
            StagedTypeChange(change: .addCheck(PluginUserDefinedTypeCheck(name: nil, expression: "VALUE > 0"), validatesExistingValues: true))
        ]

        let outcome = try await UserTypeChangeRunner.run(
            try plan(domain, changes, driver: pooled), in: scope, connection: connection, gate: AlwaysAllowGate()
        )

        #expect(outcome == .applied)
        #expect(pooled.executed == [
            "BEGIN",
            "ALTER DOMAIN posint SET NOT NULL",
            "ALTER DOMAIN posint ADD CHECK (VALUE > 0)",
            "COMMIT"
        ])
    }

    @Test("A refused change rolls the save back and names that change")
    func failureIsAttributed() async throws {
        let pooled = TypeEditStubDriver(refusing: "ADD CHECK")
        let (connection, scope) = try await install(pooled)
        defer { uninstall(connection) }
        let first = StagedTypeChange(change: .setNotNull(true))
        let refused = StagedTypeChange(
            change: .addCheck(PluginUserDefinedTypeCheck(name: nil, expression: "VALUE > 0"), validatesExistingValues: true)
        )

        let outcome = try await UserTypeChangeRunner.run(
            try plan(domain, [first, refused], driver: pooled), in: scope, connection: connection, gate: AlwaysAllowGate()
        )

        guard case .failed(let changeId, let message, let applied) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(changeId == refused.id)
        #expect(message.contains("violate the new constraint"))
        #expect(applied.isEmpty)
        #expect(pooled.executed == ["BEGIN", "ALTER DOMAIN posint SET NOT NULL", "ROLLBACK"])
    }

    /// PostgreSQL before 12 refuses `ALTER TYPE ... ADD VALUE` inside a transaction block, so a save
    /// holding one runs each step on its own and reports the steps that stand.
    @Test("A label addition the server refuses in a transaction runs on its own, and the steps before a failure stand")
    func addValueRunsInAutocommit() async throws {
        let pooled = TypeEditStubDriver(refusing: "'bad'", addsLabelsOutsideTransaction: true)
        let (connection, scope) = try await install(pooled)
        defer { uninstall(connection) }
        let glad = StagedTypeChange(change: .addEnumLabel("glad", placement: nil))
        let bad = StagedTypeChange(change: .addEnumLabel("bad", placement: nil))

        let outcome = try await UserTypeChangeRunner.run(
            try plan(mood, [glad, bad], driver: pooled), in: scope, connection: connection, gate: AlwaysAllowGate()
        )

        guard case .failed(let changeId, _, let applied) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(changeId == bad.id)
        #expect(applied == [glad.id])
        #expect(pooled.executed == ["ALTER TYPE mood ADD VALUE 'glad'"])
    }

    /// PostgreSQL 12 and later take ADD VALUE inside a block, so a later refusal takes the label back.
    @Test("A label addition the server takes in a transaction rolls back with the rest")
    func addValueRollsBackWhereAllowed() async throws {
        let pooled = TypeEditStubDriver(refusing: "'bad'")
        let (connection, scope) = try await install(pooled)
        defer { uninstall(connection) }
        let glad = StagedTypeChange(change: .addEnumLabel("glad", placement: nil))
        let bad = StagedTypeChange(change: .addEnumLabel("bad", placement: nil))

        let outcome = try await UserTypeChangeRunner.run(
            try plan(mood, [glad, bad], driver: pooled), in: scope, connection: connection, gate: AlwaysAllowGate()
        )

        guard case .failed(let changeId, _, let applied) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(changeId == bad.id)
        #expect(applied.isEmpty)
        #expect(pooled.executed == ["BEGIN", "ALTER TYPE mood ADD VALUE 'glad'", "ROLLBACK"])
    }

    @Test("An engine that cannot roll DDL back runs each step on its own")
    func nonTransactionalEngine() async throws {
        let pooled = TypeEditStubDriver(transactionalDDL: false)
        let (connection, scope) = try await install(pooled)
        defer { uninstall(connection) }

        let outcome = try await UserTypeChangeRunner.run(
            try plan(domain, [StagedTypeChange(change: .setNotNull(false))], driver: pooled),
            in: scope, connection: connection, gate: AlwaysAllowGate()
        )

        #expect(outcome == .applied)
        #expect(pooled.executed == ["ALTER DOMAIN posint DROP NOT NULL"])
    }

    @Test("A refused gate runs nothing")
    func deniedGateRunsNothing() async throws {
        let pooled = TypeEditStubDriver()
        let (connection, scope) = try await install(pooled)
        defer { uninstall(connection) }

        await #expect(throws: ExecutionGateError.self) {
            _ = try await UserTypeChangeRunner.run(
                try plan(domain, [StagedTypeChange(change: .setNotNull(true))], driver: pooled),
                in: scope, connection: connection, gate: AlwaysDenyGate()
            )
        }
        #expect(pooled.executed.isEmpty)
    }

    @Test("A change the driver has no statement for stops the plan before anything runs")
    func unsupportedChange() throws {
        let staged = StagedTypeChange(change: .dropField("x"))
        #expect(throws: UserTypeChangePlan.BuildError.unsupported(staged.summary)) {
            _ = try plan(domain, [staged], driver: TypeEditStubDriver())
        }
    }

    @Test("A drop or a retype makes the save destructive; NOT NULL does not")
    func destructiveChanges() {
        #expect(StagedTypeChange(change: .dropField("a")).isDestructive)
        #expect(StagedTypeChange(change: .dropConstraint("c")).isDestructive)
        #expect(StagedTypeChange(change: .changeFieldType(field: "a", type: "text")).isDestructive)
        #expect(!StagedTypeChange(change: .setNotNull(true)).isDestructive)
    }
}
