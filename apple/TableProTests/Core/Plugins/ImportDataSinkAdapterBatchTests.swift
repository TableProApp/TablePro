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

    static let backslashesEscape = PluginSessionLexicalState(
        determined: .backslashEscapesInSingleQuotes, enabled: .backslashEscapesInSingleQuotes
    )
    static let backslashesAreText = PluginSessionLexicalState(determined: .backslashEscapesInSingleQuotes, enabled: [])

    let declared: PluginCapabilities
    let failing: Set<String>
    var declines = false
    var batchChangesReadingRules = false
    private(set) var events: [String] = []
    private var inTransaction = false
    private var lexical = PipeliningDriver.backslashesAreText

    init(declared: PluginCapabilities = [.statementBatches], failing: Set<String> = []) {
        self.declared = declared
        self.failing = failing
    }

    var capabilities: PluginCapabilities { declared }
    var supportsTransactions: Bool { true }
    var supportsTransactionalDDL: Bool { true }
    var sessionLexicalState: PluginSessionLexicalState? { lexical }

    func execute(query: String) async throws -> PluginQueryResult {
        events.append(query)
        if failing.contains(query) { throw Refused() }
        return .empty
    }

    func executeStatements(_ statements: [PluginBatchStatement]) async throws -> [PluginBatchStatementOutcome]? {
        guard !declines else { return nil }
        events.append("batch \(statements.count)")
        if batchChangesReadingRules { lexical = Self.backslashesEscape }
        var outcomes: [PluginBatchStatementOutcome] = []
        for statement in statements {
            if failing.contains(statement.query) { return outcomes + [.failed(Refused())] }
            outcomes.append(.succeeded(rowsAffected: 1, executionTime: 0))
        }
        return outcomes
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { inTransaction ? .inTransaction : .idle }
    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        events.append("BEGIN")
        inTransaction = true
    }
    func rollbackTransaction() async throws {
        events.append("ROLLBACK")
        inTransaction = false
    }
}

struct ImportDataSinkAdapterBatchTests {
    private func sink(on driver: PipeliningDriver) -> ImportDataSinkAdapter {
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
        return ImportDataSinkAdapter(driver: adapter, databaseType: .postgresql)
    }

    @Test("Writes and definitions may wait for a batch", arguments: [
        "INSERT INTO t VALUES (1)", "update t set a = 1", "DELETE FROM t", "CREATE TABLE t (a int)",
        "ALTER TABLE t ADD b int", "COMMENT ON TABLE t IS 'x'",
    ])
    func batchesWrites(statement: String) {
        #expect(sink(on: PipeliningDriver()).batches(statement))
    }

    @Test("A transaction boundary, a setting, a call that may set one, or a text of two statements runs alone", arguments: [
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT a", "SET standard_conforming_strings = off",
        "SELECT pg_catalog.set_config('search_path', '', false)", "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)",
        "COPY t FROM STDIN", "SELECT pg_catalog.setval('s', 1, true)",
        #"INSERT INTO t SELECT pg_catalog.U&"set\005fconfig"('standard_conforming_strings', 'off', false)"#,
        "INSERT INTO t VALUES (set_config('standard_conforming_strings', 'off', false))",
    ])
    func keepsSessionStatementsAlone(statement: String) {
        #expect(!sink(on: PipeliningDriver()).batches(statement))
    }

    @Test("A connection that cannot batch never holds a statement back")
    func driverWithoutBatchesRunsAlone() {
        #expect(!sink(on: PipeliningDriver(declared: [])).batches("INSERT INTO t VALUES (1)"))
    }

    @Test("A batch the driver declines runs each statement alone, through the import's own admission")
    func declinedBatchRunsAlone() async throws {
        let driver = PipeliningDriver()
        driver.declines = true
        let sink = ImportDataSinkAdapter(
            driver: PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver),
            databaseType: .postgresql,
            importRun: ImportRun()
        )
        try await sink.prepareImportRun()
        let statements = (1...2).map { PluginImportStatement(text: "INSERT INTO t VALUES (\($0))", line: $0) }

        try await sink.execute(statements: statements)

        #expect(driver.events == statements.map(\.text))
    }

    @Test("A batch that changed how the session reads text rolls the import back, whatever the error mode")
    func changedReadingRulesRollBack() async throws {
        let driver = PipeliningDriver()
        driver.batchChangesReadingRules = true
        let sink = sink(on: driver)
        try await sink.beginTransaction()
        let statements = (1...2).map { PluginImportStatement(text: "INSERT INTO t VALUES (\($0))", line: $0) }

        do {
            try await sink.execute(statements: statements)
            Issue.record("The batch should have been refused")
        } catch let failure as PluginImportBatchFailure {
            #expect(failure.index == 1)
            #expect(failure.underlying is ImportReadingRulesChanged)
        }
        #expect(driver.events == ["BEGIN", "batch 2", "ROLLBACK"])
        try await sink.commitTransaction()
        #expect(driver.events.last == "ROLLBACK")
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
