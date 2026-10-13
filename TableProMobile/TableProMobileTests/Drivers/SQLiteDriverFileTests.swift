import Foundation
import SQLite3
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProQuery
import Testing

@Suite("SQLite driver file handling")
struct SQLiteDriverFileTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test("Opening a file that is not there fails and creates nothing")
    func missingFileIsAnError() async {
        let missing = directory.appendingPathComponent("gone.db")
        let driver = SQLiteDriver(source: .file(missing))

        await #expect(throws: LocalDatabaseFileError.unavailable(fileName: "gone.db", reason: .missing)) {
            try await driver.connect()
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("A database created new reopens later with its table intact")
    func createdDatabaseReopens() async throws {
        let file = directory.appendingPathComponent("scratch.db")
        let creator = SQLiteDriver(source: .file(file), openMode: .createNew)
        try await creator.connect()
        _ = try await creator.execute(query: "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        _ = try await creator.execute(query: "INSERT INTO notes (body) VALUES ('kept')")
        try await creator.disconnect()

        let reopened = SQLiteDriver(source: .file(file))
        try await reopened.connect()
        let result = try await reopened.execute(query: "SELECT body FROM notes")
        try await reopened.disconnect()
        let body = result.rows.first?.first ?? nil

        #expect(body == "kept")
    }

    @Test("The text from #3399, planned and run statement by statement, leaves the table holding seven rows")
    func reportedScriptInsertsSevenRows() async throws {
        let driver = try await connectedDriver("students.db")
        let script = QueryScript.plan(
            "\(Self.createStudent);\n\n\(Self.insertStudents);",
            databaseType: .sqlite,
            sendsBatchesWhole: driver.sendsBatchesWhole
        )
        var affected: [Int] = []
        for unit in script.units {
            affected.append(try await driver.execute(query: unit.sql).rowsAffected)
        }
        let count = try await driver.execute(query: "SELECT count(*) FROM STUDENT")
        try await driver.disconnect()

        #expect(affected == [0, 7])
        #expect((count.rows.first?.first ?? nil) == "7")
    }

    @Test("CREATE TABLE after a seven-row INSERT reports no rows affected, through execute and the stream")
    func createTableAfterInsertReportsZero() async throws {
        let driver = try await connectedDriver("ddl.db")
        _ = try await driver.execute(query: Self.createStudent)
        _ = try await driver.execute(query: Self.insertStudents)

        let executed = try await driver.execute(query: "CREATE TABLE executed_after (id INTEGER)")
        let streamed = try await streamedElements(driver, "CREATE TABLE streamed_after (id INTEGER)")
        try await driver.disconnect()

        let streamedCounts = streamed.compactMap { element -> Int? in
            guard case .rowsAffected(let count) = element else { return nil }
            return count
        }
        #expect(executed.rowsAffected == 0)
        #expect(streamedCounts.allSatisfy { $0 == 0 })
    }

    @Test("An INSERT that breaks a CHECK constraint throws from execute and adds no row")
    func checkViolationThrows() async throws {
        let driver = try await connectedDriver("check.db")
        _ = try await driver.execute(query: Self.createStudent)

        await #expect(throws: SQLiteError.self) {
            _ = try await driver.execute(
                query: "INSERT INTO STUDENT (SID, NAME, SEX) VALUES ('09999', 'Zed', 'X')"
            )
        }
        let count = try await driver.execute(query: "SELECT count(*) FROM STUDENT")
        try await driver.disconnect()

        #expect((count.rows.first?.first ?? nil) == "0")
    }

    @Test("A SELECT that fails on its third row streams the first two and then throws")
    func streamedRowErrorThrows() async throws {
        let driver = try await connectedDriver("json.db")
        _ = try await driver.execute(query: "CREATE TABLE j (id INTEGER PRIMARY KEY, doc TEXT)")
        _ = try await driver.execute(query: """
            INSERT INTO j (id, doc) VALUES (1, '{"a":1}'), (2, '{"a":2}'), (3, 'not json'), (4, '{"a":4}')
            """)

        var rowCount = 0
        var thrown: Error?
        do {
            let query = "SELECT id, json_extract(doc, '$.a') FROM j ORDER BY id"
            for try await element in driver.executeStreaming(query: query, options: .default) {
                if case .row = element { rowCount += 1 }
            }
        } catch {
            thrown = error
        }
        try await driver.disconnect()

        #expect(rowCount == 2)
        #expect(thrown is SQLiteError)
    }

    @Test("A consumer that stops after the first row leaves the connection free for the next statement")
    func abandonedStreamLeavesConnectionUsable() async throws {
        let driver = try await connectedDriver("abandoned.db")
        _ = try await driver.execute(query: "CREATE TABLE n (x INTEGER)")
        _ = try await driver.execute(query: """
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000)
            INSERT INTO n SELECT x FROM c
            """)

        for try await element in driver.executeStreaming(query: "SELECT x FROM n", options: .default) {
            if case .row = element { break }
        }
        let count = try await driver.execute(query: "SELECT count(*) FROM n")
        try await driver.disconnect()

        #expect((count.rows.first?.first ?? nil) == "1000")
    }

    @Test("The session reports an open transaction from BEGIN until COMMIT")
    func transactionStateFollowsBegin() async throws {
        let driver = try await connectedDriver("transaction.db")
        let before = await driver.sessionTransactionState()
        _ = try await driver.execute(query: "BEGIN")
        let inside = await driver.sessionTransactionState()
        _ = try await driver.execute(query: "COMMIT")
        let after = await driver.sessionTransactionState()
        try await driver.disconnect()
        let disconnected = await driver.sessionTransactionState()

        #expect(before == .idle)
        #expect(inside == .explicitTransaction)
        #expect(after == .idle)
        #expect(disconnected == .unknown)
    }

    @Test("A write of several statements is all or nothing when a later one breaks a constraint")
    func writeRollsBackOnALaterFailure() async throws {
        let driver = try await connectedDriver("atomic.db")
        _ = try await driver.execute(query: Self.createStudent)

        await #expect(throws: SQLiteError.self) {
            try await driver.executeWrite([
                "INSERT INTO STUDENT (SID, NAME, SEX) VALUES ('00001', 'Ann', 'F')",
                "INSERT INTO STUDENT (SID, NAME, SEX) VALUES ('00002', 'Bob', 'X')",
            ])
        }
        let count = try await driver.execute(query: "SELECT count(*) FROM STUDENT")
        let state = await driver.sessionTransactionState()
        try await driver.disconnect()

        #expect((count.rows.first?.first ?? nil) == "0")
        #expect(state == .idle)
    }

    @Test("A write inside a transaction the user opened joins it instead of opening another")
    func writeJoinsTheOpenTransaction() async throws {
        let driver = try await connectedDriver("joined.db")
        _ = try await driver.execute(query: Self.createStudent)
        _ = try await driver.execute(query: "BEGIN")

        let affected = try await driver.executeWrite([
            "INSERT INTO STUDENT (SID, NAME, SEX) VALUES ('00001', 'Ann', 'F')",
            "INSERT INTO STUDENT (SID, NAME, SEX) VALUES ('00002', 'Bob', 'M')",
        ])
        let stateAfterWrite = await driver.sessionTransactionState()
        _ = try await driver.execute(query: "ROLLBACK")
        let count = try await driver.execute(query: "SELECT count(*) FROM STUDENT")
        try await driver.disconnect()

        #expect(affected == 2)
        #expect(stateAfterWrite == .explicitTransaction)
        #expect((count.rows.first?.first ?? nil) == "0")
    }

    // MARK: - Helpers

    private static let createStudent = """
        CREATE TABLE STUDENT (
            SID   CHAR(5)      NOT NULL PRIMARY KEY,
            NAME  VARCHAR(20)  NOT NULL,
            SEX   CHAR(1)      CHECK (SEX IN ('M', 'F')),
            CLASS VARCHAR(5),
            DOB   DATE,
            SCORE INT
        )
        """

    private static let insertStudents = """
        INSERT INTO STUDENT (SID, NAME, SEX, CLASS, DOB, SCORE) VALUES
            ('03493', 'Ada',  'F', '3A', '2013-09-21', 0),
            ('03496', 'Clem', 'F', '3B', '2013-10-08', 89),
            ('03505', 'Eva',  'F', '3B', '2013-03-19', 83),
            ('03506', 'Gabe', 'M', '3C', '2013-08-23', 47),
            ('03510', 'Finn', 'M', '3B', '2013-01-24', 35),
            ('03513', 'Dio',  'M', '3C', '2013-06-25', 67),
            ('03517', 'Ben',  'M', '3A', '2013-11-17', 86)
        """

    private func connectedDriver(_ fileName: String) async throws -> SQLiteDriver {
        let driver = SQLiteDriver(source: .file(directory.appendingPathComponent(fileName)), openMode: .createNew)
        try await driver.connect()
        return driver
    }

    private func streamedElements(_ driver: SQLiteDriver, _ query: String) async throws -> [StreamElement] {
        var elements: [StreamElement] = []
        for try await element in driver.executeStreaming(query: query, options: .default) {
            elements.append(element)
        }
        return elements
    }
}

@Suite("SQLite interrupt handle")
struct SQLiteInterruptHandleTests {
    @Test("A stream's consumer interrupts only while that stream's own statement is stepping")
    func streamInterruptNeedsItsOwnStep() throws {
        let connection = try openConnection()
        defer { sqlite3_close(connection) }
        let handle = SQLiteInterruptHandle()
        handle.attach(connection)
        let browser = SQLiteStreamToken()
        let editor = SQLiteStreamToken()

        handle.interrupt(browser)
        #expect(sqlite3_is_interrupted(connection) == 0)

        handle.beginStep(of: editor)
        handle.interrupt(browser)
        #expect(sqlite3_is_interrupted(connection) == 0)
        #expect(!handle.endStep())

        handle.beginStep(of: browser)
        handle.interrupt(browser)
        #expect(sqlite3_is_interrupted(connection) == 1)
        #expect(handle.endStep())
    }

    @Test("Stop interrupts the connection whether or not a stream is stepping")
    func stopInterruptsWhateverRuns() throws {
        let connection = try openConnection()
        defer { sqlite3_close(connection) }
        let handle = SQLiteInterruptHandle()
        handle.attach(connection)
        let stream = SQLiteStreamToken()

        handle.beginStep(of: stream)
        handle.interrupt()
        #expect(handle.endStep())
        #expect(sqlite3_is_interrupted(connection) == 1)
    }

    @Test("A handle detached for a close sends no interrupt")
    func detachedHandleSendsNothing() throws {
        let connection = try openConnection()
        defer { sqlite3_close(connection) }
        let handle = SQLiteInterruptHandle()
        handle.attach(connection)
        handle.detach()
        let stream = SQLiteStreamToken()

        handle.interrupt()
        handle.beginStep(of: stream)
        handle.interrupt(stream)
        #expect(!handle.endStep())
        #expect(sqlite3_is_interrupted(connection) == 0)
    }

    private func openConnection() throws -> OpaquePointer {
        var db: OpaquePointer?
        let opened = sqlite3_open(":memory:", &db)
        let connection = try #require(db)
        try #require(opened == SQLITE_OK)
        return connection
    }
}
