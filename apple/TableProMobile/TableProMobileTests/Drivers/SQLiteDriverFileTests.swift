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

    @Test("A key written as REFERENCES parent with no column points at the parent's primary key")
    func shorthandKeyReadsTheParentPrimaryKey() async throws {
        let driver = try await connectedDriver("shorthand.db")
        _ = try await driver.execute(query: "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await driver.execute(
            query: "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES Customers)"
        )

        let keys = try await driver.fetchForeignKeys(table: "orders", schema: nil)
        try await driver.disconnect()

        #expect(keys.map(\.column) == ["customer_id"])
        #expect(keys.map(\.referencedTable) == ["Customers"])
        #expect(keys.map(\.referencedColumn) == ["id"])
    }

    @Test("A shorthand key to a parent with a non-ASCII name still reads the parent's primary key")
    func shorthandKeyToNonASCIIParent() async throws {
        let driver = try await connectedDriver("non-ascii.db")
        _ = try await driver.execute(query: "CREATE TABLE \"Équipe\" (id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await driver.execute(
            query: "CREATE TABLE members (id INTEGER PRIMARY KEY, team_id INTEGER REFERENCES \"Équipe\")"
        )

        let keys = try await driver.fetchForeignKeys(table: "members", schema: nil)
        try await driver.disconnect()

        #expect(keys.map(\.referencedTable) == ["Équipe"])
        #expect(keys.map(\.referencedColumn) == ["id"])
    }

    @Test("The pairs of a composite key share one name, and another key gets its own")
    func compositeKeyPairsShareAName() async throws {
        let driver = try await connectedDriver("composite.db")
        _ = try await driver.execute(query: "CREATE TABLE regions (id INTEGER PRIMARY KEY)")
        _ = try await driver.execute(
            query: "CREATE TABLE users (tenant_id INTEGER, id INTEGER, name TEXT, PRIMARY KEY (tenant_id, id))"
        )
        _ = try await driver.execute(query: """
            CREATE TABLE orders (
                id INTEGER PRIMARY KEY,
                tid INTEGER,
                uid INTEGER,
                region_id INTEGER REFERENCES regions (id),
                CONSTRAINT fk_order_user FOREIGN KEY (tid, uid) REFERENCES users (tenant_id, id)
            )
            """)

        let keys = try await driver.fetchForeignKeys(table: "orders", schema: nil)
        try await driver.disconnect()

        let userPairs = keys.filter { $0.referencedTable == "users" }
        let regionKeys = keys.filter { $0.referencedTable == "regions" }
        #expect(userPairs.count == 2)
        #expect(Set(userPairs.map(\.name)).count == 1)
        #expect(userPairs.map(\.column) == ["tid", "uid"])
        #expect(userPairs.map(\.referencedColumn) == ["tenant_id", "id"])
        #expect(regionKeys.map(\.column) == ["region_id"])
        #expect(regionKeys.allSatisfy { $0.name != userPairs.first?.name })
    }

    @Test("A declared name equal to another key's positional name keeps the two keys apart")
    func declaredNameDoesNotMergeKeys() async throws {
        let driver = try await connectedDriver("collision.db")
        _ = try await driver.execute(query: "CREATE TABLE p (id INTEGER PRIMARY KEY)")
        _ = try await driver.execute(query: """
            CREATE TABLE orders (
                id INTEGER PRIMARY KEY,
                a INTEGER,
                b INTEGER,
                CONSTRAINT fk_orders_0 FOREIGN KEY (a) REFERENCES p (id),
                FOREIGN KEY (b) REFERENCES p (id)
            )
            """)

        let keys = try await driver.fetchForeignKeys(table: "orders", schema: nil)
        try await driver.disconnect()

        #expect(keys.count == 2)
        #expect(Set(keys.map(\.name)).count == 2)
        let reference = ForeignKeyReference.make(
            forColumn: "b",
            foreignKeys: keys,
            columns: ["id", "a", "b"].map { ColumnInfo(name: $0, typeName: "INTEGER") },
            cells: [.text("9"), .text("1"), .text("2")],
            sourceSchema: nil
        )
        #expect(reference?.parts == [ForeignKeyReference.Part(column: "id", value: "2")])
    }

    // A column declared with no type keeps integer 5 and text '6' apart, so a quoted key missed the integer row.
    @Test("A key column with no type finds its row whether it holds an integer or text")
    func untypedKeyFindsEitherStorageClass() async throws {
        let driver = try await connectedDriver("untyped-key.db")
        _ = try await driver.execute(query: "CREATE TABLE p (id PRIMARY KEY, name)")
        _ = try await driver.execute(query: "INSERT INTO p VALUES (5, 'integer'), ('6', 'text'), ('05', 'padded'), (7, 'seven')")
        let columns = try await driver.fetchColumns(table: "p", schema: nil)

        var names: [String: String] = [:]
        for value in ["5", "6", "05"] {
            let query = SQLBuilder.buildSingleRowLookup(
                table: "p", schema: nil, key: [(column: "id", value: value)],
                columns: columns, type: .sqlite, driver: driver
            )
            let rows = try await driver.execute(query: query).rows
            names[value] = rows.count == 1 ? rows[0][1] : nil
        }
        try await driver.disconnect()

        #expect(names == ["5": "integer", "6": "text", "05": "padded"])
    }

    @Test("Update and delete through a key column with no type reach the integer row and only it")
    func untypedKeyUpdatesAndDeletes() async throws {
        let driver = try await connectedDriver("untyped-write.db")
        _ = try await driver.execute(query: "CREATE TABLE p (id PRIMARY KEY, name)")
        _ = try await driver.execute(query: "INSERT INTO p VALUES (5, 'before'), (7, 'kept')")
        let columns = try await driver.fetchColumns(table: "p", schema: nil)
        let key = [(column: "id", value: "5")]

        try await driver.executeWrite([SQLBuilder.buildUpdate(
            table: "p", schema: nil, type: .sqlite, driver: driver,
            changes: [(column: "name", value: "after")], primaryKeys: key, columns: columns
        )])
        let updated = try await driver.execute(query: "SELECT name FROM p WHERE id = 5")
        try await driver.executeWrite([SQLBuilder.buildDelete(
            table: "p", schema: nil, type: .sqlite, driver: driver, primaryKeys: key, columns: columns
        )])
        let remaining = try await driver.execute(query: "SELECT id, name FROM p")
        try await driver.disconnect()

        #expect((updated.rows.first?.first ?? nil) == "after")
        #expect(remaining.rows == [["7", "kept"]])
    }

    // Integer 5 and text '5' are two keys in a column with no type, and both read as 5.
    @MainActor
    @Test("A delete through a key two rows share is refused and both rows stay")
    func sharedUntypedKeyRefusesTheWrite() async throws {
        let driver = try await connectedDriver("shared-key.db")
        _ = try await driver.execute(query: "CREATE TABLE p (id PRIMARY KEY, name)")
        _ = try await driver.execute(query: "INSERT INTO p VALUES (5, 'integer'), ('5', 'text'), (6, 'alone')")
        let browser = DataBrowserViewModel()
        browser.attach(
            session: ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "main"),
            table: TableInfo(name: "p"), databaseType: .sqlite, host: ""
        )
        await browser.load(isInitial: true)

        let shared = await browser.deleteRow(pkValues: [(column: "id", value: "5")])
        let sharedError = browser.operationError?.title
        let alone = await browser.deleteRow(pkValues: [(column: "id", value: "6")])
        let remaining = try await driver.execute(query: "SELECT name FROM p ORDER BY name")
        try await driver.disconnect()

        #expect(!shared)
        #expect(sharedError == String(localized: "Key Matches Several Rows"))
        #expect(alone)
        #expect(remaining.rows == [["integer"], ["text"]])
    }

    @Test("A result column with no declared type that holds only blobs reads as BLOB")
    func untypedBlobColumnReadsAsBlob() async throws {
        let driver = try await connectedDriver("untyped-blob.db")
        _ = try await driver.execute(query: "CREATE TABLE p (id INTEGER PRIMARY KEY, tag, note)")
        _ = try await driver.execute(query: "INSERT INTO p VALUES (1, x'0102', 'a'), (2, NULL, x'03')")
        let result = try await driver.execute(query: "SELECT tag, note, id FROM p ORDER BY id")
        try await driver.disconnect()

        #expect(result.columns.map(\.typeName) == ["BLOB", "", "INTEGER"])
    }

    @MainActor
    @Test("A preview finds a row behind a key with no type, and a blob in a key column with no type is no link")
    func previewOverUntypedKeys() async throws {
        let driver = try await connectedDriver("untyped-preview.db")
        _ = try await driver.execute(query: "CREATE TABLE q (k PRIMARY KEY)")
        _ = try await driver.execute(query: "CREATE TABLE p (id PRIMARY KEY, tag REFERENCES q (k))")
        _ = try await driver.execute(query: "INSERT INTO q VALUES (x'0102')")
        _ = try await driver.execute(query: "INSERT INTO p VALUES (5, x'0102')")
        let model = ForeignKeyPreviewModel(
            reference: ForeignKeyReference(table: "p", schema: nil, parts: [.init(column: "id", value: "5")]),
            session: ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "main"),
            databaseType: .sqlite
        )
        await model.load()
        try await driver.disconnect()

        #expect(model.isLoaded)
        #expect(model.fields.map(\.name) == ["id", "tag"])
        #expect(model.fields.allSatisfy { $0.reference == nil })
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
