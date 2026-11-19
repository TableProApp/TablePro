//
//  ImportDataSinkAdapterBatchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class PipeliningDriver: PluginDriverStub, @unchecked Sendable {
    struct Refused: Error {}

    let declared: PluginCapabilities
    let failing: Set<String>
    private(set) var events: [String] = []

    init(declared: PluginCapabilities = [.statementBatches], failing: Set<String> = []) {
        self.declared = declared
        self.failing = failing
    }

    var capabilities: PluginCapabilities { declared }
    var supportsTransactions: Bool { true }
    var supportsTransactionalDDL: Bool { true }

    func execute(query: String) async throws -> PluginQueryResult {
        events.append(query)
        if failing.contains(query) { throw Refused() }
        return .empty
    }

    func executeStatements(_ statements: [PluginBatchStatement]) async throws -> [PluginBatchStatementOutcome]? {
        events.append("batch \(statements.count)")
        var outcomes: [PluginBatchStatementOutcome] = []
        for statement in statements {
            if failing.contains(statement.query) { return outcomes + [.failed(Refused())] }
            outcomes.append(.succeeded(rowsAffected: 1, executionTime: 0))
        }
        return outcomes
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { .inTransaction }
}

struct ImportDataSinkAdapterBatchTests {
    private func sink(on driver: PipeliningDriver) -> ImportDataSinkAdapter {
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
        return ImportDataSinkAdapter(driver: adapter, databaseType: .postgresql)
    }

    @Test("Writes and definitions may wait for a batch", arguments: [
        "INSERT INTO t VALUES (1)", "update t set a = 1", "DELETE FROM t", "CREATE TABLE t (a int)",
        "ALTER TABLE t ADD b int", "COMMENT ON TABLE t IS 'x'", "SELECT pg_catalog.setval('s', 1, true)",
    ])
    func batchesWrites(statement: String) {
        #expect(sink(on: PipeliningDriver()).batches(statement))
    }

    @Test("A transaction boundary, a session setting or a text of two statements runs alone", arguments: [
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT a", "SET standard_conforming_strings = off",
        "SELECT pg_catalog.set_config('search_path', '', false)", "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)",
        "COPY t FROM STDIN",
    ])
    func keepsSessionStatementsAlone(statement: String) {
        #expect(!sink(on: PipeliningDriver()).batches(statement))
    }

    @Test("A connection that cannot batch never holds a statement back")
    func driverWithoutBatchesRunsAlone() {
        #expect(!sink(on: PipeliningDriver(declared: [])).batches("INSERT INTO t VALUES (1)"))
    }

    @Test("A batch goes to the driver in one call, and its first failure names that statement")
    func failureNamesItsStatement() async throws {
        let statements = (1...3).map { PluginImportStatement(text: "INSERT INTO t VALUES (\($0))", line: $0 * 10) }
        let driver = PipeliningDriver(failing: [statements[1].text])

        do {
            try await sink(on: driver).execute(statements: statements)
            Issue.record("The batch should have failed at its second statement")
        } catch let failure as PluginImportBatchFailure {
            #expect(failure.index == 1)
            #expect(failure.underlying is PipeliningDriver.Refused)
        }
        #expect(driver.events == ["batch 3"])
    }
}
