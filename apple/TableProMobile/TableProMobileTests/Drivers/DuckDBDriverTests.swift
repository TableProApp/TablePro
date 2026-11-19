import CDuckDB
import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing
import XCTest

final class DuckDBDriverTests: XCTestCase {
    private var driver: DuckDBDriver?

    override func setUp() async throws {
        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        self.driver = driver
    }

    func testMissingFileIsAnErrorAndCreatesNothing() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-missing-\(UUID().uuidString).duckdb")
        let fileDriver = DuckDBDriver(source: .file(missing))

        do {
            try await fileDriver.connect()
            XCTFail("Opening a missing DuckDB file must fail")
        } catch {
            XCTAssertEqual(
                error as? LocalDatabaseFileError,
                .unavailable(fileName: missing.lastPathComponent, reason: .missing)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testCreatedDatabaseReopensWithItsTable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cube.duckdb")

        let creator = DuckDBDriver(source: .file(file), openMode: .createNew)
        try await creator.connect()
        _ = try await creator.execute(query: "CREATE TABLE facts (id INTEGER, label VARCHAR)")
        _ = try await creator.execute(query: "INSERT INTO facts VALUES (1, 'kept')")
        try await creator.disconnect()

        let reopened = DuckDBDriver(source: .file(file))
        try await reopened.connect()
        let result = try await reopened.execute(query: "SELECT label FROM facts")
        try await reopened.disconnect()

        XCTAssertEqual(result.rows.first?.first ?? nil, "kept")
    }

    override func tearDown() async throws {
        try await driver?.disconnect()
        driver = nil
    }

    private func streamedRows(_ driver: DuckDBDriver, _ query: String) async throws -> [[String?]] {
        var rows: [[String?]] = []
        for try await element in driver.executeStreaming(query: query, options: .default) {
            if case .row(let row) = element {
                rows.append(row.cells.map { cell -> String? in
                    if case .null = cell { return nil }
                    return cell.displayString
                })
            }
        }
        return rows
    }

    func testStreamingMatchesMaterializedAcrossTypes() async throws {
        let driver = try XCTUnwrap(driver)
        let query = """
            SELECT
                42::INTEGER AS i,
                9223372036854775807::BIGINT AS big,
                170141183460469231731687303715884105727::HUGEINT AS huge,
                (-170141183460469231731687303715884105727)::HUGEINT AS huge_neg,
                3.5::DOUBLE AS d,
                true AS b,
                'hello' AS s,
                NULL::INTEGER AS n,
                DATE '2024-03-09' AS dt,
                TIMESTAMP '2024-03-09 12:34:56.789' AS tstamp,
                'abc'::BLOB AS payload,
                '550e8400-e29b-41d4-a716-446655440000'::UUID AS uid,
                12.34::DECIMAL(5,2) AS dec,
                INTERVAL '1' MONTH AS iv,
                [1, 2, 3] AS lst,
                {'a': 1, 'b': 2} AS strct
            """
        let materialized = try await driver.execute(query: query)
        let streamed = try await streamedRows(driver, query)

        XCTAssertEqual(streamed.count, 1)
        XCTAssertEqual(materialized.rows.count, 1)
        // A streamed BLOB is a binary cell, as on every other engine; `execute` still carries its base64.
        let payload = 10
        XCTAssertEqual(streamed[0][payload], Cell.binary(byteCount: 3, ref: nil).displayString)
        XCTAssertEqual(materialized.rows[0][payload], Data("abc".utf8).base64EncodedString())
        var streamedRest = streamed[0]
        var materializedRest = materialized.rows[0]
        streamedRest.remove(at: payload)
        materializedRest.remove(at: payload)
        XCTAssertEqual(streamedRest, materializedRest, "streamed output must match the materialized path for every other type")
    }

    func testStreamingMultiRowOrder() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: "CREATE TABLE nums (id INTEGER, label VARCHAR)")
        _ = try await driver.execute(query: "INSERT INTO nums SELECT i, 'row' || i FROM range(1, 2001) t(i)")
        let streamed = try await streamedRows(driver, "SELECT id, label FROM nums ORDER BY id")
        XCTAssertEqual(streamed.count, 2_000)
        XCTAssertEqual(streamed.first, ["1", "row1"])
        XCTAssertEqual(streamed.last, ["2000", "row2000"])
    }

    func testExecuteRendersComplexAndScalarTypes() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: """
            SELECT [1,2,3] AS lst, {'a':1,'b':2} AS strct, 12.34::DECIMAL(5,2) AS dec,
            '550e8400-e29b-41d4-a716-446655440000'::UUID AS uid, DATE '2024-03-09' AS dt,
            TIMESTAMP '2024-03-09 12:34:56' AS ts, 'abc'::BLOB AS payload
            """)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0][0], "[1, 2, 3]")
        XCTAssertEqual(result.rows[0][1], "{'a': 1, 'b': 2}")
        XCTAssertEqual(result.rows[0][2], "12.34")
        XCTAssertEqual(result.rows[0][3], "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(result.rows[0][4], "2024-03-09")
    }

    func testPing() async throws {
        let driver = try XCTUnwrap(driver)
        let alive = try await driver.ping()
        XCTAssertTrue(alive)
    }

    func testPingInsideAnAbortedTransactionKeepsTheSession() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: "CREATE TABLE keep (x INTEGER)")
        _ = try await driver.execute(query: "INSERT INTO keep VALUES (1)")
        _ = try await driver.execute(query: "CREATE TABLE u (x INTEGER PRIMARY KEY)")
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        _ = try await driver.execute(query: "INSERT INTO u VALUES (1)")
        do {
            _ = try await driver.execute(query: "INSERT INTO u VALUES (1)")
            XCTFail("A duplicate key must fail")
        } catch {}
        do {
            _ = try await driver.execute(query: "SELECT 1")
            XCTFail("An aborted DuckDB transaction must refuse a statement")
        } catch {}

        let alive = try await driver.ping()
        XCTAssertTrue(alive)

        _ = try await driver.execute(query: "ROLLBACK")
        let kept = try await driver.execute(query: "SELECT x FROM keep")
        XCTAssertEqual(kept.rows.first?.first ?? nil, "1")
    }

    func testPingAfterDisconnectFails() async throws {
        let closed = DuckDBDriver(source: .inMemory)
        try await closed.connect()
        try await closed.disconnect()
        do {
            _ = try await closed.ping()
            XCTFail("A closed DuckDB session must fail its ping")
        } catch DuckDBDriverError.notConnected {}
    }

    func testServerVersionIsReported() async throws {
        let driver = try XCTUnwrap(driver)
        XCTAssertNotNil(driver.serverVersion)
    }

    func testCreateInsertSelect() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: "CREATE TABLE items (id INTEGER PRIMARY KEY, label VARCHAR, active BOOLEAN)")
        _ = try await driver.execute(query: "INSERT INTO items VALUES (1, 'first', true), (2, 'second', false)")

        let result = try await driver.execute(query: "SELECT id, label, active FROM items ORDER BY id")
        XCTAssertEqual(result.columns.map(\.name), ["id", "label", "active"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0], ["1", "first", "true"])
        XCTAssertEqual(result.rows[1], ["2", "second", "false"])
    }

    func testTimestampTzRendersAsText() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT TIMESTAMPTZ '2024-01-02 03:04:05+00' AS ts")
        XCTAssertEqual(result.rows.count, 1)
        let value = try XCTUnwrap(result.rows[0][0])
        XCTAssertTrue(value.contains("2024-01-02"), "expected rendered timestamptz, got \(value)")
    }

    func testVariantRendersAsText() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT {'a': 42, 'b': [1, 2, 3]}::VARIANT AS v")
        XCTAssertEqual(result.rows.count, 1)
        let value = try XCTUnwrap(result.rows[0][0])
        XCTAssertTrue(value.contains("42"), "expected rendered variant text, got \(value)")
    }

    func testStreamThrowsAnErrorRaisedAfterItsFirstChunks() async throws {
        let driver = try XCTUnwrap(driver)
        // A 1 MB buffer holds about 128k rows of a streaming result ahead of the reader, so the failing row lies past
        // it and the error comes from a fetch rather than from executing the query. DuckDB 2.0's default is 10 MiB.
        _ = try await driver.execute(query: "SET streaming_buffer_size = '1MB'")
        let query = "SELECT CASE WHEN i = 250000 THEN error('boom at 250000') ELSE i END AS v FROM range(250001) t(i)"
        var rows = 0
        do {
            for try await element in driver.executeStreaming(query: query, options: StreamOptions(maxRows: 1_000_000)) {
                if case .row = element { rows += 1 }
            }
            XCTFail("a stream whose later rows fail must throw, not end after \(rows) rows")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("boom at 250000"), "unexpected error: \(error)")
        }
        XCTAssertGreaterThan(rows, 0, "the error must come from a later fetch for this test to cover it")
    }

    func testSupersededStreamCannotReadOrEndTheNextStream() async throws {
        let actor = try XCTUnwrap(driver).actor
        guard case .rowSet(_, let first) = try await actor.beginStream(
            query: "SELECT i FROM range(5) t(i)", token: DuckDBStreamToken()
        ) else {
            return XCTFail("a SELECT must stream")
        }
        guard case .rowSet(_, let second) = try await actor.beginStream(
            query: "SELECT i FROM range(100, 103) t(i)", token: DuckDBStreamToken()
        ) else {
            return XCTFail("a SELECT must stream")
        }

        do {
            _ = try await actor.fetchStreamChunk(stream: first, options: .default)
            XCTFail("a superseded stream must not read the stream that replaced it")
        } catch is CancellationError {}

        await actor.endStream(first)
        let chunk = try await actor.fetchStreamChunk(stream: second, options: .default)
        XCTAssertEqual(chunk?.map { $0.first?.displayString }, ["100", "101", "102"])
        await actor.endStream(second)
    }

    func testAnotherStatementEndsTheOpenStreamAsCancelled() async throws {
        let driver = try XCTUnwrap(driver)
        guard case .rowSet(_, let stream) = try await driver.actor.beginStream(
            query: "SELECT i FROM range(100000) t(i)", token: DuckDBStreamToken()
        ) else {
            return XCTFail("a SELECT must stream")
        }
        _ = try await driver.actor.fetchStreamChunk(stream: stream, options: .default)

        _ = try await driver.execute(query: "SELECT 42")

        do {
            _ = try await driver.actor.fetchStreamChunk(stream: stream, options: .default)
            XCTFail("a stream closed by another statement must end as cancelled")
        } catch is CancellationError {}
    }

    func testCancellingTheConsumerInterruptsTheRunningQuery() async throws {
        let driver = try XCTUnwrap(driver)
        // About 30 seconds of work on ten cores, all of it before the first chunk is ready.
        let query = "SELECT sum(i) FROM range(50000000000) t(i)"
        let consumer = Task {
            for try await _ in driver.executeStreaming(query: query, options: .default) {}
        }
        try await Task.sleep(for: .milliseconds(300))
        consumer.cancel()

        let start = ContinuousClock.now
        let alive = try await driver.ping()
        XCTAssertTrue(alive)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "the cancel must interrupt the query, not queue behind it")
    }

    func testCancelWithoutRunningQueryIsSafe() async throws {
        let driver = try XCTUnwrap(driver)
        try await driver.cancelCurrentQuery()
        let alive = try await driver.ping()
        XCTAssertTrue(alive)
    }

    func testNullRendersAsNil() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT NULL AS value")
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertNil(result.rows[0][0])
    }

    func testFetchTablesAndColumns() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: "CREATE TABLE people (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL)")

        let tables = try await driver.fetchTables(schema: "main")
        XCTAssertTrue(tables.contains { $0.name == "people" && $0.type == .table })

        let columns = try await driver.fetchColumns(table: "people", schema: "main")
        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        let idColumn = try XCTUnwrap(columns.first { $0.name == "id" })
        XCTAssertTrue(idColumn.isPrimaryKey)
        let nameColumn = try XCTUnwrap(columns.first { $0.name == "name" })
        XCTAssertFalse(nameColumn.isNullable)
    }

    func testFetchSchemasIncludesMain() async throws {
        let driver = try XCTUnwrap(driver)
        let schemas = try await driver.fetchSchemas()
        XCTAssertTrue(schemas.contains("main"))
    }

    func testViewIsReportedAsView() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: "CREATE TABLE base (n INTEGER)")
        _ = try await driver.execute(query: "CREATE VIEW base_view AS SELECT n FROM base")

        let tables = try await driver.fetchTables(schema: "main")
        let view = try XCTUnwrap(tables.first { $0.name == "base_view" })
        XCTAssertEqual(view.type, .view)
    }

    func testBlobIsBase64Encoded() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT 'abc'::BLOB AS payload")
        XCTAssertEqual(result.rows[0][0], Data("abc".utf8).base64EncodedString())
    }
}

struct DuckDBBlobStreamingTests {
    @Test("A streamed BLOB is a binary cell of its byte count, with the ref every other column gets")
    func blobStreamsAsBinary() async throws {
        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE files (id INTEGER PRIMARY KEY, payload BLOB)")
        _ = try await driver.execute(query: "INSERT INTO files VALUES (1, 'abc'::BLOB)")
        let options = StreamOptions(maxRows: 10, lazyContext: LazyContext(table: "files", primaryKeyColumns: ["id"]))

        var cells: [Cell] = []
        for try await element in driver.executeStreaming(query: "SELECT id, payload FROM files", options: options) {
            if case .row(let row) = element { cells = row.cells }
        }
        try await driver.disconnect()

        guard cells.count == 2, case .binary(let byteCount, let ref) = cells[1] else {
            Issue.record("the BLOB should stream as a binary cell, got \(cells)")
            return
        }
        #expect(byteCount == 3)
        #expect(ref?.primaryKey == [PrimaryKeyComponent(column: "id", value: "1")])
    }
}

struct DuckDBDriverTransactionStateTests {
    private func connectedDriver() async throws -> DuckDBDriver {
        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        return driver
    }

    @Test("A new session holds no transaction")
    func idleAfterConnect() async throws {
        let driver = try await connectedDriver()
        #expect(await driver.sessionTransactionState() == .idle)
        try await driver.disconnect()
    }

    @Test("BEGIN opens a transaction and COMMIT ends it")
    func beginThenCommit() async throws {
        let driver = try await connectedDriver()
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        #expect(await driver.sessionTransactionState() == .explicitTransaction)
        _ = try await driver.execute(query: "COMMIT")
        #expect(await driver.sessionTransactionState() == .idle)
        try await driver.disconnect()
    }

    @Test("A statement that fails inside a transaction leaves it aborted until ROLLBACK")
    func failureInsideTransactionAborts() async throws {
        let driver = try await connectedDriver()
        _ = try await driver.execute(query: "CREATE TABLE u (x INTEGER PRIMARY KEY)")
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        _ = try await driver.execute(query: "INSERT INTO u VALUES (1)")
        await #expect(throws: (any Error).self) {
            try await driver.execute(query: "INSERT INTO u VALUES (1)")
        }
        #expect(await driver.sessionTransactionState() == .abortedTransaction)
        _ = try await driver.execute(query: "ROLLBACK")
        #expect(await driver.sessionTransactionState() == .idle)
        try await driver.disconnect()
    }

    @Test("Asking twice inside a transaction keeps it and its row for the COMMIT")
    func probingKeepsTheTransactionForCommit() async throws {
        let driver = try await connectedDriver()
        _ = try await driver.execute(query: "CREATE TABLE kept (x INTEGER)")
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        _ = try await driver.execute(query: "INSERT INTO kept VALUES (1)")
        #expect(await driver.sessionTransactionState() == .explicitTransaction)
        #expect(await driver.sessionTransactionState() == .explicitTransaction)
        _ = try await driver.execute(query: "COMMIT")
        let rows = try await driver.execute(query: "SELECT x FROM kept").rows
        #expect(rows == [["1"]])
        try await driver.disconnect()
    }

    @Test("Asking inside a transaction commits nothing, so a ROLLBACK still undoes the row")
    func probingCommitsNothing() async throws {
        let driver = try await connectedDriver()
        _ = try await driver.execute(query: "CREATE TABLE undone (x INTEGER)")
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        _ = try await driver.execute(query: "INSERT INTO undone VALUES (1)")
        #expect(await driver.sessionTransactionState() == .explicitTransaction)
        _ = try await driver.execute(query: "ROLLBACK")
        let rows = try await driver.execute(query: "SELECT count(*) FROM undone").rows
        #expect(rows == [["0"]])
        try await driver.disconnect()
    }

    @Test("An open stream is left running and the state is not guessed")
    func openStreamIsNotEnded() async throws {
        let driver = try await connectedDriver()
        guard case .rowSet(_, let stream) = try await driver.actor.beginStream(
            query: "SELECT i FROM range(100000) t(i)", token: DuckDBStreamToken()
        ) else {
            Issue.record("a SELECT must stream")
            return
        }
        _ = try await driver.actor.fetchStreamChunk(stream: stream, options: .default)
        #expect(await driver.sessionTransactionState() == .unknown)
        let next = try await driver.actor.fetchStreamChunk(stream: stream, options: .default)
        #expect(next?.isEmpty == false)
        await driver.actor.endStream(stream)
        #expect(await driver.sessionTransactionState() == .idle)
        try await driver.disconnect()
    }

    @Test("A session that is not open cannot say")
    func unopenedSessionIsUnknown() async throws {
        #expect(await DuckDBDriver(source: .inMemory).sessionTransactionState() == .unknown)
        let closed = try await connectedDriver()
        try await closed.disconnect()
        #expect(await closed.sessionTransactionState() == .unknown)
    }
}

struct DuckDBTransactionProbeTests {
    @Test("Only DuckDB's own catalog goes on to the transaction id")
    func nativeCatalogIsProbedFurther() {
        #expect(DuckDBTransactionProbe.state(catalogType: .value("duckdb")) == nil)
        #expect(DuckDBTransactionProbe.state(catalogType: .value("DuckDB")) == nil)
    }

    @Test("Another engine's catalog is never asked for a transaction id")
    func foreignCatalogIsUnknown() {
        #expect(DuckDBTransactionProbe.state(catalogType: .value("sqlite")) == .unknown)
        #expect(DuckDBTransactionProbe.state(catalogType: .value("postgres")) == .unknown)
    }

    @Test("A refused catalog read is an aborted transaction, an unreadable one says nothing")
    func catalogRefusals() {
        #expect(DuckDBTransactionProbe.state(catalogType: .abortedTransaction) == .abortedTransaction)
        #expect(DuckDBTransactionProbe.state(catalogType: .unreadable) == .unknown)
    }

    @Test("Two ids that differ are two statements' own transactions, the same id is one open transaction")
    func transactionIds() {
        #expect(DuckDBTransactionProbe.state(first: .value("6"), second: .value("10")) == .idle)
        #expect(DuckDBTransactionProbe.state(first: .value("12"), second: .value("12")) == .explicitTransaction)
    }

    @Test("An aborted reading wins, and an unreadable one says nothing")
    func transactionIdRefusals() {
        #expect(DuckDBTransactionProbe.state(first: .abortedTransaction, second: .unreadable) == .abortedTransaction)
        #expect(DuckDBTransactionProbe.state(first: .value("12"), second: .abortedTransaction) == .abortedTransaction)
        #expect(DuckDBTransactionProbe.state(first: .value("12"), second: .unreadable) == .unknown)
        #expect(DuckDBTransactionProbe.state(first: .unreadable, second: .value("12")) == .unknown)
    }
}

struct DuckDBDriverStorageVersionTests {
    @Test("A database the driver creates or attaches stays readable by DuckDB 1.x")
    func createdAndAttachedFilesStayOnAOneXStorageVersion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attached = directory.appendingPathComponent("side.duckdb")

        let driver = DuckDBDriver(source: .file(directory.appendingPathComponent("cube.duckdb")), openMode: .createNew)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE facts (id INTEGER)")
        _ = try await driver.execute(query: "ATTACH '\(attached.path)' AS side")
        _ = try await driver.execute(query: "CREATE TABLE side.facts (id INTEGER)")
        let rows = try await driver.execute(query: """
            SELECT database_name, tags['storage_version'] FROM duckdb_databases()
            WHERE database_name IN ('cube', 'side') ORDER BY database_name
            """).rows
        try await driver.disconnect()

        #expect(rows.map { $0[0] } == ["cube", "side"])
        #expect(rows.allSatisfy { $0[1]?.hasPrefix("v1.") == true })
    }
}

struct DuckDBNulTextTests {
    @Test("NUL text inserts and edits by its whole primary key")
    func nulTextInsertsAndEditsByItsKeyWhole() async throws {
        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE notes (id VARCHAR PRIMARY KEY, body VARCHAR)")
        let columns = try await driver.fetchColumns(table: "notes", schema: nil)
        let key = "k\u{0}1"
        let insert = try #require(SQLBuilder.buildInsert(
            table: "notes", schema: nil, type: .duckdb, driver: driver, columns: ["id", "body"], values: [key, "a\u{0}b"]
        ))
        try await driver.executeWrite([insert, "INSERT INTO notes VALUES ('k', 'other')"])
        let inserted = try await driver.execute(query: "SELECT body FROM notes WHERE body <> 'other'")

        try await driver.executeWrite([SQLBuilder.buildUpdate(
            table: "notes", schema: nil, type: .duckdb, driver: driver,
            changes: [(column: "body", value: "x\u{0}y")], primaryKeys: [(column: "id", value: key)], columns: columns
        )])
        let after = try await driver.execute(query: "SELECT id, body FROM notes ORDER BY id")

        try await driver.disconnect()
        #expect(inserted.rows == [["a\u{0}b"]])
        #expect(after.rows == [["k", "other"], [key, "x\u{0}y"]])
    }
}

// Built past DuckDB's default limit on a stack that holds it, as another program could.
private actor DeepDuckDBFileWriter {
    private let executor = DuckDBStackExecutor(name: "DeepDuckDBFileWriter")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    func create(_ path: String, check: String) -> Bool {
        var config: duckdb_config?
        var database: duckdb_database?
        var connection: duckdb_connection?
        defer {
            duckdb_disconnect(&connection)
            duckdb_close(&database)
            duckdb_destroy_config(&config)
        }
        guard duckdb_create_config(&config) != DuckDBError,
              duckdb_set_config(config, "max_expression_depth", "100000") != DuckDBError,
              duckdb_open_ext(path, &database, config, nil) != DuckDBError,
              duckdb_connect(database, &connection) != DuckDBError
        else { return false }
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        return duckdb_query(connection, "CREATE TABLE t (a INTEGER CHECK (\(check) > 0)); CHECKPOINT", &result)
            != DuckDBError
    }
}

struct DuckDBDeepExpressionTests {
    private func deepFile(in directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("deep.duckdb")
        let check = String(repeating: "(", count: 900) + "a" + String(repeating: " + 1)", count: 900)
        #expect(await DeepDuckDBFileWriter().create(file.path, check: check))
        return file
    }

    @Test("A CHECK nested 900 deep opens, and reading its table's keys fails at the depth limit instead of overflowing")
    func deepCheckOpensAndItsKeysAreRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)

        let driver = DuckDBDriver(source: .file(file))
        try await driver.connect()
        let refusal = await #expect(throws: DuckDBDriverError.self) {
            try await driver.fetchColumns(table: "t", schema: nil)
        }
        try await driver.disconnect()

        #expect(refusal?.localizedDescription.contains("Max expression depth limit of 250 exceeded") == true)
    }

    @Test("An ATTACH of a file nested 900 deep reads its catalog without overflowing")
    func deepFileAttaches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-attach-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)

        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY)")
        let tables = try await driver.execute(query: "SELECT table_name FROM duckdb_tables() WHERE database_name = 'deep'")
        try await driver.disconnect()

        #expect(tables.rows == [["t"]])
    }

    @Test("A file nested 900 deep attaches a hundred times, each read on a thread with DuckDB's stack")
    func deepFileAttachesRepeatedly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-reattach-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)

        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        for _ in 0..<100 {
            _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY)")
            _ = try await driver.execute(query: "DETACH deep")
        }
        let threads = try await driver.execute(query: "SELECT current_setting('threads'), current_setting('external_threads')")
        try await driver.disconnect()

        let count = String(ProcessInfo.processInfo.processorCount)
        #expect(threads.rows == [[count, count]])
    }

    @Test(
        "A raised thread count is taken over, a deep file still attaches, and a count below it is refused",
        .timeLimit(.minutes(1))
    )
    func raisedThreadCountIsTakenOver() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-threads-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)

        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        let base = ProcessInfo.processInfo.processorCount
        var counts: [[String?]] = []
        for statement in [
            "SET threads = \(base + 8)", "PRAGMA threads = \(base + 16)", "EXPLAIN ANALYZE SET threads = \(base + 24)",
        ] {
            _ = try await driver.execute(query: statement)
            for _ in 0..<20 {
                _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY)")
                _ = try await driver.execute(query: "DETACH deep")
            }
            counts += try await driver.execute(
                query: "SELECT current_setting('threads'), current_setting('external_threads')"
            ).rows
        }
        let lowering = await #expect(throws: DuckDBDriverError.self) {
            try await driver.execute(query: "SET threads = \(base)")
        }
        try await driver.disconnect()

        let raised = [base + 8, base + 16, base + 24].map { [String($0), String($0)] as [String?] }
        #expect(counts == raised)
        #expect(lowering?.localizedDescription.contains("external threads") == true)
    }

    @Test(
        "A text of several statements takes each raised count over before the next statement reads a deep file",
        .timeLimit(.minutes(1))
    )
    func threadCountFollowsSetsInOneText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-text-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)

        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        let base = ProcessInfo.processInfo.processorCount
        let selected = try await driver.execute(
            query: "SET threads = \(base + 8); SET threads = \(base + 16); SELECT 42"
        )
        var threads = base + 16
        for _ in 0..<20 {
            threads += 1
            _ = try await driver.execute(
                query: "SET threads = \(threads); ATTACH '\(file.path)' AS deep (READ_ONLY); DETACH deep"
            )
        }
        _ = try await driver.execute(query: "SET threads = \(base + 48); SET lock_configuration = true")
        for _ in 0..<20 {
            _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY); DETACH deep")
        }
        let counts = try await driver.execute(query: "SELECT current_setting('threads'), current_setting('external_threads')")
        try await driver.disconnect()

        #expect(selected.rows == [["42"]])
        #expect(counts.rows == [[String(base + 48), String(base + 48)]])
    }

    @Test("A text DuckDB cannot parse runs none of its statements")
    func unparsedTextRunsNothing() async throws {
        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        await #expect(throws: DuckDBDriverError.self) {
            try await driver.execute(query: "SET threads = 64; CREATE TABLE never (i INTEGER); SELEC 1")
        }
        let counts = try await driver.execute(query: "SELECT current_setting('threads'), current_setting('external_threads')")
        let tables = try await driver.execute(query: "SELECT count(*) FROM duckdb_tables() WHERE table_name = 'never'")
        try await driver.disconnect()

        let all = String(ProcessInfo.processInfo.processorCount)
        #expect(counts.rows == [[all, all]])
        #expect(tables.rows == [["0"]])
    }

    @Test(
        "An import whose statements raise the count and lock the configuration leaves the threads to the app",
        .timeLimit(.minutes(1))
    )
    func importThatLocksIsTakenOver() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)
        let folder = directory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raised = String(ProcessInfo.processInfo.processorCount + 40)
        try "SET threads = \(raised);\nSET lock_configuration = true;\n".write(
            to: folder.appendingPathComponent("schema.sql"), atomically: true, encoding: .utf8
        )
        try "".write(to: folder.appendingPathComponent("load.sql"), atomically: true, encoding: .utf8)

        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "IMPORT DATABASE '\(folder.path)'")
        for _ in 0..<20 {
            _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY)")
            _ = try await driver.execute(query: "DETACH deep")
        }
        let counts = try await driver.execute(query: "SELECT current_setting('threads'), current_setting('external_threads')")
        try await driver.disconnect()

        #expect(counts.rows == [[raised, raised]])
    }

    @Test("A SET that fails for another reason runs once")
    func failedSetRunsOnce() async throws {
        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE SEQUENCE seq")
        await #expect(throws: DuckDBDriverError.self) {
            try await driver.execute(
                query: "SET VARIABLE x = CASE WHEN nextval('seq') = 1 THEN error('fails once') ELSE 42 END"
            )
        }
        let current = try await driver.execute(query: "SELECT currval('seq')")
        try await driver.disconnect()

        #expect(current.rows == [["1"]])
    }

    @Test("A text of several statements returns the result DuckDB picks for it")
    func severalStatementsKeepTheirResult() async throws {
        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        let wrapped = try await driver.execute(query: "BEGIN; SELECT 123; COMMIT")
        let first = try await driver.execute(query: "SELECT 123; SELECT 456")
        try await driver.disconnect()

        #expect(wrapped.rows == [["123"]])
        #expect(first.rows == [["123"]])
    }

    @Test("A locked configuration keeps DuckDB's tasks on threads with its stack")
    func lockedConfigurationKeepsTheThreads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-locked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)

        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "SET lock_configuration = true")
        for _ in 0..<20 {
            _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY)")
            _ = try await driver.execute(query: "DETACH deep")
        }
        let counts = try await driver.execute(query: "SELECT current_setting('threads'), current_setting('external_threads')")
        try await driver.disconnect()

        let all = String(ProcessInfo.processInfo.processorCount)
        #expect(counts.rows == [[all, all]])
    }
}
