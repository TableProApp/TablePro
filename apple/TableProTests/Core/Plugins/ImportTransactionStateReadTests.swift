//
//  ImportTransactionStateReadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Counts the transaction state reads, which are a round trip on SQL Server.
private final class StateCountingDriver: PluginDriverStub, @unchecked Sendable {
    private(set) var stateReads = 0
    private(set) var executed: [String] = []
    private var inTransaction = false

    var capabilities: PluginCapabilities { [.statementBatches] }
    var supportsTransactions: Bool { true }
    var supportsTransactionalDDL: Bool { true }

    func execute(query: String) async throws -> PluginQueryResult {
        executed.append(query)
        return .empty
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        executed.append(query)
        return .empty
    }

    func executeStatements(_ statements: [PluginBatchStatement]) async throws -> [PluginBatchStatementOutcome]? {
        executed += statements.map(\.query)
        return statements.map { _ in .succeeded(rowsAffected: 1, executionTime: 0) }
    }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        stateReads += 1
        return inTransaction ? .inTransaction : .idle
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        inTransaction = true
    }
}

struct ImportTransactionStateReadTests {
    private func preparedSink(on driver: StateCountingDriver) async throws -> ImportDataSinkAdapter {
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
        let sink = ImportDataSinkAdapter(driver: adapter, databaseType: .postgresql, importRun: ImportRun())
        try await sink.prepareImportRun()
        return sink
    }

    @Test("Inside the import's transaction a plain INSERT that succeeds reads no transaction state after it")
    func plainInsertReadsNoState() async throws {
        let driver = StateCountingDriver()
        let sink = try await preparedSink(on: driver)
        try await sink.beginTransaction()
        let before = driver.stateReads

        for line in 1...50 {
            try await sink.execute(statement: "INSERT INTO t VALUES (\(line), 'row')", line: line)
        }

        #expect(driver.executed.count == 50)
        #expect(driver.stateReads == before)
    }

    @Test("Inside the import's transaction a row batch reads no transaction state after it")
    func rowBatchReadsNoState() async throws {
        let driver = StateCountingDriver()
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
        let sink = ImportDataSinkAdapter(
            driver: adapter, databaseType: .postgresql, targetTable: "t",
            columnMapping: ["id": "id"], sourceFields: ["id"], importRun: ImportRun()
        )
        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        // The first batch reads the target's columns once, and that read is followed by a state read.
        try await sink.insertRows([["id": .text("0")]])
        let before = driver.stateReads
        let sent = driver.executed.count

        for batch in 1...5 {
            try await sink.insertRows([["id": .text("\(batch)")]])
        }

        #expect(driver.executed.count == sent + 5)
        #expect(driver.stateReads == before)
    }

    @Test("Outside a transaction a plain INSERT is followed by a state read, since it can open one implicitly")
    func insertOutsideATransactionReadsState() async throws {
        let driver = StateCountingDriver()
        let sink = try await preparedSink(on: driver)
        let before = driver.stateReads

        try await sink.execute(statement: "INSERT INTO t VALUES (1)", line: 1)

        #expect(driver.stateReads == before + 1)
    }

    @Test("A statement that can end or open a transaction is followed by a state read", arguments: [
        "COMMIT",
        "BEGIN",
        "CREATE TABLE t (id int)",
        "CALL archive_orders()",
        "INSERT INTO t VALUES (1)\nCOMMIT TRANSACTION",
        "SET autocommit = 0"
    ])
    func transactionStatementReadsState(statement: String) async throws {
        let driver = StateCountingDriver()
        let sink = try await preparedSink(on: driver)
        try await sink.beginTransaction()
        let before = driver.stateReads

        try await sink.execute(statement: statement, line: 1)

        #expect(driver.stateReads == before + 1)
    }

    @Test("Statements sent together inside the import's transaction read the state only when one can move it")
    func batchedStatementsReadStateOnlyWhenOneCanMoveIt() async throws {
        let driver = StateCountingDriver()
        let sink = try await preparedSink(on: driver)
        try await sink.beginTransaction()
        let inserts = (1...3).map { PluginImportStatement(text: "INSERT INTO t VALUES (\($0))", line: $0) }

        let before = driver.stateReads
        try await sink.execute(statements: inserts, readAhead: false)
        #expect(driver.executed.suffix(3) == inserts.map(\.text))
        #expect(driver.stateReads == before)

        try await sink.execute(
            statements: inserts + [PluginImportStatement(text: "CREATE TABLE u (id int)", line: 4)], readAhead: false
        )
        #expect(driver.executed.last == "CREATE TABLE u (id int)")
        #expect(driver.stateReads == before + 1)
    }

    @Test("Words that can move a transaction are found anywhere in the text, in any case, and only as whole words", arguments: [
        ("INSERT INTO t VALUES (1)", false),
        ("insert into t values ('committed')", false),
        ("INSERT INTO t SELECT * FROM transactions", false),
        ("INSERT INTO t EXEC load_rows", true),
        ("insert into t values (1);\ncommit", true),
        ("UPDATE t SET a = 1 -- then rollback", true),
        ("INSERT INTO go_live VALUES (1)", false),
        ("INSERT INTO t VALUES (1)\nGO", true),
        ("INSERT INTO t VALUES ('é tran')", true),
        ("insert into t values (1);\nend", true),
        ("DELETE FROM t WHERE reason = 'aborted'", false)
    ])
    func transactionWords(text: String, expected: Bool) {
        #expect(ImportTransactionWords.mayNameOne(text) == expected)
    }
}

struct ImportRowWriterMappingPlanTests {
    @Test("Rows with the same fields map alike, and a row with other fields gets its own mapping")
    func mappingFollowsEachRowsFields() {
        let writer = ImportRowWriter(
            databaseTypeId: "PostgreSQL",
            columnMapping: ["Name": "name", "Age": "age"],
            sourceFields: ["Name", "Age"],
            rowWriting: .insert
        )

        let first = writer.mappedColumnsAndValues(["Name": .text("Ann"), "Age": .text("40")])
        let second = writer.mappedColumnsAndValues(["Age": .text("7"), "Name": .text("Bo")])
        let other = writer.mappedColumnsAndValues(["name": .text("Cy"), "extra": .text("x")])

        #expect(first.0 == ["age", "name"])
        #expect(first.1 == [.text("40"), .text("Ann")])
        #expect(second.0 == ["age", "name"])
        #expect(second.1 == [.text("7"), .text("Bo")])
        #expect(other.0 == ["name"])
        #expect(other.1 == [.text("Cy")])
    }
}
