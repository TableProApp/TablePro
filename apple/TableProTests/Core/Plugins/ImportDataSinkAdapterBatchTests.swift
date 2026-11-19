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
    var lexical: PluginSessionLexicalState? = PipeliningDriver.backslashesAreText
    // Where a statement leaves the session's reading rules, as a function that sets them would.
    var rulesAfter: [String: PluginSessionLexicalState] = [:]
    private(set) var events: [String] = []
    private var inTransaction = false

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
        if let rules = rulesAfter[query] { lexical = rules }
        return .empty
    }

    func executeStatements(_ statements: [PluginBatchStatement]) async throws -> [PluginBatchStatementOutcome]? {
        guard !declines else { return nil }
        events.append("batch \(statements.count)")
        var outcomes: [PluginBatchStatementOutcome] = []
        for statement in statements {
            if failing.contains(statement.query) { return outcomes + [.failed(Refused())] }
            if let rules = rulesAfter[statement.query] { lexical = rules }
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
    private func sink(on driver: PipeliningDriver, importRun: ImportRun? = nil) -> ImportDataSinkAdapter {
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
        return ImportDataSinkAdapter(driver: adapter, databaseType: .postgresql, importRun: importRun)
    }

    private static func statements(_ count: Int) -> [PluginImportStatement] {
        (1...count).map { PluginImportStatement(text: "INSERT INTO t VALUES (\($0))", line: $0) }
    }

    @Test("Writes and definitions may wait for a batch", arguments: [
        "INSERT INTO t VALUES (1)", "update t set a = 1", "DELETE FROM t", "CREATE TABLE t (a int)",
        "ALTER TABLE t ADD b int", "COMMENT ON TABLE t IS 'x'", "INSERT INTO t VALUES ($$a;b$$)",
    ])
    func batchesWrites(statement: String) {
        #expect(sink(on: PipeliningDriver()).batches(statement))
    }

    @Test("A transaction boundary, a setting, a read, a call that may set one, or a text of two statements runs alone", arguments: [
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT a", "SET standard_conforming_strings = off",
        "SELECT pg_catalog.set_config('search_path', '', false)", "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)",
        "COPY t FROM STDIN", "SELECT pg_catalog.setval('s', 1, true)",
        "INSERT INTO t VALUES (set_config('standard_conforming_strings', 'off', false))",
    ])
    func keepsSessionStatementsAlone(statement: String) {
        #expect(!sink(on: PipeliningDriver()).batches(statement))
    }

    @Test("Text holding a backslash runs alone, since the session's rules decide where it ends", arguments: [
        #"INSERT INTO t VALUES ('a\'b')"#, #"INSERT INTO t VALUES (E'\n')"#, #"COMMENT ON TABLE t IS 'C:\dir'"#,
        #"INSERT INTO t SELECT pg_catalog.U&"set\005fconfig"('standard_conforming_strings', 'off', false)"#,
    ])
    func keepsBackslashesAlone(statement: String) {
        #expect(!sink(on: PipeliningDriver()).batches(statement))
    }

    @Test("A connection that cannot batch never holds a statement back")
    func driverWithoutBatchesRunsAlone() {
        #expect(!sink(on: PipeliningDriver(declared: [])).batches("INSERT INTO t VALUES (1)"))
    }

    @Test("A session that decides more than backslash escapes never batches, since other text could split differently")
    func sessionDecidingOtherRulesRunsAlone() {
        let driver = PipeliningDriver()
        driver.lexical = PluginSessionLexicalState(
            determined: [.backslashEscapesInSingleQuotes, .hashLineComments], enabled: []
        )

        #expect(!sink(on: driver).batches("INSERT INTO t VALUES (1)"))
    }

    @Test("A batch the driver declines runs each statement alone, through the import's own admission")
    func declinedBatchRunsAlone() async throws {
        let driver = PipeliningDriver()
        driver.declines = true
        let sink = sink(on: driver, importRun: ImportRun())
        try await sink.prepareImportRun()
        let statements = Self.statements(2)

        try await sink.execute(statements: statements, readAhead: false)

        let texts = statements.map(\.text)
        #expect(driver.events == texts)
    }

    @Test("A batch that changed how the session reads text fails at the statement read past it, and rolls nothing back itself")
    func changedRulesStopTheReadAhead() async throws {
        let statements = Self.statements(2)
        let driver = PipeliningDriver()
        driver.rulesAfter = [statements[0].text: PipeliningDriver.backslashesEscape]
        let sink = sink(on: driver)
        try await sink.beginTransaction()

        do {
            try await sink.execute(statements: statements, readAhead: true)
            Issue.record("The statement read past the batch should be refused")
        } catch let failure as PluginImportBatchFailure {
            #expect(failure.index == statements.count)
            #expect(failure.underlying is ImportReadingRulesChanged)
        }
        #expect(driver.events == ["BEGIN", "batch 2"])
    }

    @Test("Changed rules leave a batch alone when the file was not read past it")
    func changedRulesWithoutReadAhead() async throws {
        let statements = Self.statements(2)
        let driver = PipeliningDriver()
        driver.rulesAfter = [statements[0].text: PipeliningDriver.backslashesEscape]
        let sink = sink(on: driver)
        try await sink.beginTransaction()

        try await sink.execute(statements: statements, readAhead: false)

        #expect(driver.events == ["BEGIN", "batch 2"])
    }

    @Test("Rules a batch changes and changes back leave the statement read past it as it was read")
    func restoredRulesKeepTheReadAhead() async throws {
        let statements = Self.statements(2)
        let driver = PipeliningDriver()
        driver.rulesAfter = [
            statements[0].text: PipeliningDriver.backslashesEscape,
            statements[1].text: PipeliningDriver.backslashesAreText,
        ]
        let sink = sink(on: driver)
        try await sink.beginTransaction()

        try await sink.execute(statements: statements, readAhead: true)

        #expect(driver.events == ["BEGIN", "batch 2"])
    }

    @Test("Statements the driver declined and ran alone are held to the same rule")
    func declinedBatchThatChangedRules() async throws {
        let statements = Self.statements(2)
        let driver = PipeliningDriver()
        driver.declines = true
        driver.rulesAfter = [statements[1].text: PipeliningDriver.backslashesEscape]

        do {
            try await sink(on: driver).execute(statements: statements, readAhead: true)
            Issue.record("The statement read past the batch should be refused")
        } catch let failure as PluginImportBatchFailure {
            #expect(failure.index == statements.count)
            #expect(failure.underlying is ImportReadingRulesChanged)
        }
        let texts = statements.map(\.text)
        #expect(driver.events == texts)
    }

    @Test("A batch goes to the driver in one call, and its first failure names that statement")
    func failureNamesItsStatement() async throws {
        let statements = (1...3).map { PluginImportStatement(text: "INSERT INTO t VALUES (\($0))", line: $0 * 10) }
        let driver = PipeliningDriver(failing: [statements[1].text])

        do {
            try await sink(on: driver).execute(statements: statements, readAhead: true)
            Issue.record("The batch should have failed at its second statement")
        } catch let failure as PluginImportBatchFailure {
            #expect(failure.index == 1)
            #expect(failure.underlying is PipeliningDriver.Refused)
        }
        #expect(driver.events == ["batch 3"])
    }
}
