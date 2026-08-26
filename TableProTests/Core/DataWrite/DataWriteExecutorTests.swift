//
//  DataWriteExecutorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

/// Reports whatever affected-row count the test asks for, and remembers whether it was rolled back.
private final class CountingDriver: PluginDatabaseDriver, @unchecked Sendable {
    let affectedRows: Int
    let transactional: Bool
    private(set) var executed: [String] = []
    private(set) var didCommit = false
    private(set) var didRollBack = false

    init(affectedRows: Int, transactional: Bool = true) {
        self.affectedRows = affectedRows
        self.transactional = transactional
    }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { transactional }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        executed.append(query)
        return PluginQueryResult(
            columns: [], columnTypeNames: [], rows: [], rowsAffected: affectedRows, executionTime: 0
        )
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {}
    func commitTransaction() async throws { didCommit = true }
    func rollbackTransaction() async throws { didRollBack = true }

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
    private func plan(expectedRowCount: Int?) -> DataWritePlan {
        DataWritePlan(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            databaseType: .sqlite,
            steps: [
                DataWriteStep(
                    kind: .rowWrite,
                    statement: ParameterizedStatement(sql: "UPDATE \"t\" SET \"b\" = ? WHERE \"a\" = ?", parameters: ["x", "1"]),
                    expectedRowCount: expectedRowCount,
                    tableName: "t"
                ),
            ]
        )
    }

    private func driver(_ counting: CountingDriver) -> DatabaseDriver {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .sqlite), pluginDriver: counting)
    }

    @Test("The driver's real affected-row count reaches the caller")
    func reportsRealRowCount() async throws {
        let counting = CountingDriver(affectedRows: 42)
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: 50), on: driver(counting))

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
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: 1), on: driver(counting))

        #expect(results.first?.rowsAffected == 0)
        #expect(counting.didCommit)
        #expect(counting.didRollBack == false)
    }

    @Test("A statement whose row count carries no meaning is not held to one")
    func unverifiedStepIsNotChecked() async throws {
        let counting = CountingDriver(affectedRows: 9_999)
        let results = try await DataWriteExecutor.run(plan(expectedRowCount: nil), on: driver(counting))

        #expect(results.first?.wasVerified == false)
        #expect(counting.didCommit)
    }
}
