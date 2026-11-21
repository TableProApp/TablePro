import CDuckDB
import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

private func connectedDuckDB() async throws -> DuckDBBackedDriver {
    let driver = DuckDBBackedDriver(source: .inMemory)
    try await driver.connect()
    return driver
}

private func scratchDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct DuckDBDriverFileTests {
    @Test("A missing file is an error and creates nothing")
    func missingFileIsAnError() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-missing-\(UUID().uuidString).duckdb")

        await #expect(throws: LocalDatabaseFileError.unavailable(fileName: missing.lastPathComponent, reason: .missing)) {
            try await DuckDBBackedDriver(source: .file(missing)).connect()
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("A created database reopens with its table, its file closed by the first driver's disconnect")
    func createdDatabaseReopens() async throws {
        let directory = try scratchDirectory("duckdb-create")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cube.duckdb")

        let creator = DuckDBBackedDriver(source: .file(file), openMode: .createNew)
        try await creator.connect()
        _ = try await creator.execute(query: "CREATE TABLE facts (id INTEGER, label VARCHAR)")
        _ = try await creator.execute(query: "INSERT INTO facts VALUES (1, 'kept')")
        try await creator.disconnect()

        let reopened = DuckDBBackedDriver(source: .file(file))
        try await reopened.connect()
        let result = try await reopened.execute(query: "SELECT label FROM facts")
        try await reopened.disconnect()

        #expect(result.rows == [["kept"]])
    }

    @Test("A database the driver creates or attaches stays readable by DuckDB 1.x")
    func createdAndAttachedFilesStayOnAOneXStorageVersion() async throws {
        let directory = try scratchDirectory("duckdb-storage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let attached = directory.appendingPathComponent("side.duckdb")

        let driver = DuckDBBackedDriver(source: .file(directory.appendingPathComponent("cube.duckdb")), openMode: .createNew)
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

    @Test("No extension is installed or loaded from the network on iOS")
    func extensionDownloadsStayOff() async throws {
        let driver = try await connectedDuckDB()
        let settings = try await driver.execute(query: """
            SELECT current_setting('autoinstall_known_extensions'), current_setting('autoload_known_extensions')
            """).rows
        let json = try await driver.execute(query: "SELECT json_extract('{\"a\": 7}', '$.a')").rows
        try await driver.disconnect()

        #expect(settings == [["false", "false"]])
        #expect(json == [["7"]])
    }
}

struct DuckDBDriverQueryTests {
    private func streamedRows(_ driver: DuckDBBackedDriver, _ query: String) async throws -> [[String?]] {
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

    @Test("A streamed row reads as the materialized one for every type, a BLOB as a binary cell")
    func streamingMatchesMaterialized() async throws {
        let driver = try await connectedDuckDB()
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
        try await driver.disconnect()

        let payload = 10
        try #require(streamed.count == 1 && materialized.rows.count == 1)
        #expect(streamed[0][payload] == Cell.binary(byteCount: 3, ref: nil).displayString)
        // A materialized BLOB is spelled in hex, as every plugin-backed engine spells one.
        #expect(materialized.rows[0][payload] == "616263")
        var streamedRest = streamed[0]
        var materializedRest = materialized.rows[0]
        streamedRest.remove(at: payload)
        materializedRest.remove(at: payload)
        #expect(streamedRest == materializedRest)
    }

    @Test("Rows stream in order")
    func streamingMultiRowOrder() async throws {
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "CREATE TABLE nums (id INTEGER, label VARCHAR)")
        _ = try await driver.execute(query: "INSERT INTO nums SELECT i, 'row' || i FROM range(1, 2001) t(i)")
        let streamed = try await streamedRows(driver, "SELECT id, label FROM nums ORDER BY id")
        try await driver.disconnect()

        #expect(streamed.count == 2_000)
        #expect(streamed.first == ["1", "row1"])
        #expect(streamed.last == ["2000", "row2000"])
    }

    @Test("A read is capped at the row limit and says so")
    func readIsCapped() async throws {
        let driver = try await connectedDuckDB()
        var rows = 0
        var cappedAt: Int?
        for try await element in driver.executeStreaming(
            query: "SELECT i FROM range(1000) t(i)", options: StreamOptions(maxRows: 10)
        ) {
            switch element {
            case .row: rows += 1
            case .truncated(reason: .rowCap(let cap)): cappedAt = cap
            default: break
            }
        }
        try await driver.disconnect()

        #expect(rows == 10)
        #expect(cappedAt == 10)
    }

    @Test("Complex and scalar types render as text")
    func executeRendersComplexAndScalarTypes() async throws {
        let driver = try await connectedDuckDB()
        let result = try await driver.execute(query: """
            SELECT [1,2,3] AS lst, {'a':1,'b':2} AS strct, 12.34::DECIMAL(5,2) AS dec,
            '550e8400-e29b-41d4-a716-446655440000'::UUID AS uid, DATE '2024-03-09' AS dt
            """)
        try await driver.disconnect()

        #expect(result.rows == [["[1, 2, 3]", "{'a': 1, 'b': 2}", "12.34", "550e8400-e29b-41d4-a716-446655440000", "2024-03-09"]])
    }

    @Test("TIMESTAMPTZ and VARIANT render as text")
    func sessionSpelledTypesRender() async throws {
        let driver = try await connectedDuckDB()
        let stamp = try await driver.execute(query: "SELECT TIMESTAMPTZ '2024-01-02 03:04:05+00' AS ts").rows
        let variant = try await driver.execute(query: "SELECT {'a': 42, 'b': [1, 2, 3]}::VARIANT AS v").rows
        try await driver.disconnect()

        #expect(stamp.first?.first??.contains("2024-01-02") == true)
        #expect(variant.first?.first??.contains("42") == true)
    }

    @Test("A NULL reads as nil")
    func nullRendersAsNil() async throws {
        let driver = try await connectedDuckDB()
        let result = try await driver.execute(query: "SELECT NULL AS value")
        try await driver.disconnect()

        #expect(result.rows == [[nil]])
    }

    @Test("CREATE, INSERT and SELECT round-trip")
    func createInsertSelect() async throws {
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "CREATE TABLE items (id INTEGER PRIMARY KEY, label VARCHAR, active BOOLEAN)")
        _ = try await driver.execute(query: "INSERT INTO items VALUES (1, 'first', true), (2, 'second', false)")
        let result = try await driver.execute(query: "SELECT id, label, active FROM items ORDER BY id")
        try await driver.disconnect()

        #expect(result.columns.map(\.name) == ["id", "label", "active"])
        #expect(result.rows == [["1", "first", "true"], ["2", "second", "false"]])
    }

    @Test("A stream whose later rows fail throws instead of ending early")
    func streamThrowsALaterError() async throws {
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "SET streaming_buffer_size = '1MB'")
        let query = "SELECT CASE WHEN i = 250000 THEN error('boom at 250000') ELSE i END AS v FROM range(250001) t(i)"

        let failure = await #expect(throws: (any Error).self) {
            for try await _ in driver.executeStreaming(query: query, options: StreamOptions(maxRows: 1_000_000)) {}
        }
        try await driver.disconnect()

        #expect(failure?.localizedDescription.contains("boom at 250000") == true)
    }

    @Test("A statement sent while a stream is read leaves both whole")
    func statementBesideAStream() async throws {
        let driver = try await connectedDuckDB()
        var iterator = driver.executeStreaming(query: "SELECT i FROM range(100000) t(i)", options: StreamOptions(maxRows: 200_000))
            .makeAsyncIterator()
        _ = try await iterator.next()
        let other = try await driver.execute(query: "SELECT 42")
        var rows = 0
        while let element = try await iterator.next() {
            if case .row = element { rows += 1 }
        }
        try await driver.disconnect()

        #expect(other.rows == [["42"]])
        #expect(rows == 100_000)
    }

    @Test("A text of several statements is refused and runs none of them, as on the Mac")
    func severalStatementsAreRefused() async throws {
        let driver = try await connectedDuckDB()
        await #expect(throws: (any Error).self) {
            try await driver.execute(query: "CREATE TABLE never (i INTEGER); SELECT 456")
        }
        let tables = try await driver.execute(query: "SELECT count(*) FROM duckdb_tables() WHERE table_name = 'never'")
        try await driver.disconnect()

        #expect(tables.rows == [["0"]])
    }

    @Test("NUL text inserts and edits by its whole primary key")
    func nulTextInsertsAndEditsByItsKeyWhole() async throws {
        let driver = try await connectedDuckDB()
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

struct DuckDBDriverSessionTests {
    @Test("Ping answers on an open session")
    func ping() async throws {
        let driver = try await connectedDuckDB()
        let alive = try await driver.ping()
        try await driver.disconnect()

        #expect(alive)
        #expect(driver.serverVersion != nil)
    }

    @Test("Ping inside an aborted transaction keeps the session and its transaction")
    func pingInsideAnAbortedTransaction() async throws {
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "CREATE TABLE keep (x INTEGER)")
        _ = try await driver.execute(query: "INSERT INTO keep VALUES (1)")
        _ = try await driver.execute(query: "CREATE TABLE u (x INTEGER PRIMARY KEY)")
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        _ = try await driver.execute(query: "INSERT INTO u VALUES (1)")
        await #expect(throws: (any Error).self) { try await driver.execute(query: "INSERT INTO u VALUES (1)") }
        await #expect(throws: (any Error).self) { try await driver.execute(query: "SELECT 1") }

        let alive = try await driver.ping()
        _ = try await driver.execute(query: "ROLLBACK")
        let kept = try await driver.execute(query: "SELECT x FROM keep")
        try await driver.disconnect()

        #expect(alive)
        #expect(kept.rows == [["1"]])
    }

    @Test("Ping after a disconnect fails")
    func pingAfterDisconnectFails() async throws {
        let driver = try await connectedDuckDB()
        try await driver.disconnect()

        await #expect(throws: (any Error).self) { _ = try await driver.ping() }
    }

    @Test("Stop interrupts the running query rather than queueing behind it")
    func cancellingTheConsumerInterruptsTheQuery() async throws {
        let driver = try await connectedDuckDB()
        // About 30 seconds of work on ten cores, all of it before the first chunk is ready.
        let consumer = Task {
            for try await _ in driver.executeStreaming(query: "SELECT sum(i) FROM range(50000000000) t(i)", options: .default) {}
        }
        try await Task.sleep(for: .milliseconds(300))
        consumer.cancel()

        let start = ContinuousClock.now
        let alive = try await driver.ping()
        let waited = ContinuousClock.now - start
        try await driver.disconnect()

        #expect(alive)
        #expect(waited < .seconds(5))
    }

    @Test("A cancel with nothing running is harmless")
    func cancelWithoutRunningQueryIsSafe() async throws {
        let driver = try await connectedDuckDB()
        try await driver.cancelCurrentQuery()
        let alive = try await driver.ping()
        try await driver.disconnect()

        #expect(alive)
    }
}

struct DuckDBDriverCatalogTests {
    @Test("Tables and columns list with their keys and nullability")
    func fetchTablesAndColumns() async throws {
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "CREATE TABLE people (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL)")
        _ = try await driver.execute(query: "CREATE VIEW people_view AS SELECT name FROM people")
        let tables = try await driver.fetchTables(schema: "main")
        let columns = try await driver.fetchColumns(table: "people", schema: "main")
        let schemas = try await driver.fetchSchemas()
        try await driver.disconnect()

        #expect(tables.contains { $0.name == "people" && $0.type == .table })
        #expect(tables.contains { $0.name == "people_view" && $0.type == .view })
        #expect(columns.map(\.name) == ["id", "name"])
        #expect(columns.map(\.isPrimaryKey) == [true, false])
        #expect(columns.map(\.isNullable) == [false, false])
        #expect(schemas.contains("main"))
    }

    @Test("A schema switch moves where unqualified names read")
    func switchSchema() async throws {
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "CREATE SCHEMA side")
        _ = try await driver.execute(query: "CREATE TABLE side.only_here (x INTEGER)")
        try await driver.switchSchema(to: "side")
        let tables = try await driver.fetchTables(schema: nil)
        let read = try await driver.execute(query: "SELECT count(*) FROM only_here")
        let current = driver.currentSchema
        try await driver.disconnect()

        #expect(current == "side")
        #expect(tables.map(\.name) == ["only_here"])
        #expect(read.rows == [["0"]])
    }
}

struct DuckDBBlobStreamingTests {
    @Test("A streamed BLOB is a binary cell of its byte count, with the ref every other column gets")
    func blobStreamsAsBinary() async throws {
        let driver = try await connectedDuckDB()
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
    @Test("A new session holds no transaction")
    func idleAfterConnect() async throws {
        let driver = try await connectedDuckDB()
        #expect(await driver.sessionTransactionState() == .idle)
        try await driver.disconnect()
    }

    @Test("BEGIN opens a transaction and COMMIT ends it")
    func beginThenCommit() async throws {
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        #expect(await driver.sessionTransactionState() == .explicitTransaction)
        _ = try await driver.execute(query: "COMMIT")
        #expect(await driver.sessionTransactionState() == .idle)
        try await driver.disconnect()
    }

    @Test("A statement that fails inside a transaction leaves it aborted until ROLLBACK")
    func failureInsideTransactionAborts() async throws {
        let driver = try await connectedDuckDB()
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
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "CREATE TABLE kept (x INTEGER)")
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        _ = try await driver.execute(query: "INSERT INTO kept VALUES (1)")
        #expect(await driver.sessionTransactionState() == .explicitTransaction)
        #expect(await driver.sessionTransactionState() == .explicitTransaction)
        _ = try await driver.execute(query: "COMMIT")
        let rows = try await driver.execute(query: "SELECT x FROM kept").rows
        try await driver.disconnect()

        #expect(rows == [["1"]])
    }

    @Test("Asking inside a transaction commits nothing, so a ROLLBACK still undoes the row")
    func probingCommitsNothing() async throws {
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "CREATE TABLE undone (x INTEGER)")
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        _ = try await driver.execute(query: "INSERT INTO undone VALUES (1)")
        #expect(await driver.sessionTransactionState() == .explicitTransaction)
        _ = try await driver.execute(query: "ROLLBACK")
        let rows = try await driver.execute(query: "SELECT count(*) FROM undone").rows
        try await driver.disconnect()

        #expect(rows == [["0"]])
    }

    @Test("A streamed read leaves the session idle")
    func streamedReadLeavesTheSessionIdle() async throws {
        let driver = try await connectedDuckDB()
        for try await _ in driver.executeStreaming(query: "SELECT i FROM range(100000) t(i)", options: .default) {}
        #expect(await driver.sessionTransactionState() == .idle)
        try await driver.disconnect()
    }

    @Test("A session that is not open cannot say")
    func unopenedSessionIsUnknown() async throws {
        #expect(await DuckDBBackedDriver(source: .inMemory).sessionTransactionState() == .unknown)
        let closed = try await connectedDuckDB()
        try await closed.disconnect()
        #expect(await closed.sessionTransactionState() == .unknown)
    }
}

struct DuckDBTransactionProbeTests {
    @Test("Only DuckDB's own catalog goes on to the transaction id")
    func nativeCatalogIsProbedFurther() {
        #expect(DuckDBTransactionProbe.state(catalogType: .value("duckdb"), tracksOpenTransaction: false) == nil)
        #expect(DuckDBTransactionProbe.state(catalogType: .value("DuckDB"), tracksOpenTransaction: true) == nil)
    }

    @Test("Another engine's catalog answers from the statements the driver saw, never from a transaction id")
    func foreignCatalogFollowsTrackedStatements() {
        #expect(DuckDBTransactionProbe.state(catalogType: .value("sqlite"), tracksOpenTransaction: false) == .idle)
        #expect(DuckDBTransactionProbe.state(catalogType: .value("postgres"), tracksOpenTransaction: true) == .inTransaction)
    }

    @Test("A refused catalog read is an aborted transaction, an unreadable one says nothing")
    func catalogRefusals() {
        #expect(DuckDBTransactionProbe.state(catalogType: .abortedTransaction, tracksOpenTransaction: false) == .abortedTransaction)
        #expect(DuckDBTransactionProbe.state(catalogType: .unreadable, tracksOpenTransaction: false) == .unknown)
    }

    @Test("Two ids that differ are two statements' own transactions, the same id is one open transaction")
    func transactionIds() {
        #expect(DuckDBTransactionProbe.state(first: .value("6"), second: .value("10")) == .idle)
        #expect(DuckDBTransactionProbe.state(first: .value("12"), second: .value("12")) == .inTransaction)
        #expect(DuckDBTransactionProbe.state(first: .abortedTransaction, second: .unreadable) == .abortedTransaction)
        #expect(DuckDBTransactionProbe.state(first: .value("12"), second: .unreadable) == .unknown)
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

    private func threadCounts(_ driver: DuckDBBackedDriver) async throws -> [[String?]] {
        try await driver.execute(query: "SELECT current_setting('threads'), current_setting('external_threads')").rows
    }

    @Test("A CHECK nested 900 deep opens, and reading its table's keys fails at the depth limit instead of overflowing")
    func deepCheckOpensAndItsKeysAreRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)

        let driver = DuckDBBackedDriver(source: .file(file))
        try await driver.connect()
        let refusal = await #expect(throws: (any Error).self) {
            try await driver.fetchColumns(table: "t", schema: nil)
        }
        try await driver.disconnect()

        #expect(refusal?.localizedDescription.contains("Max expression depth limit of 250 exceeded") == true)
    }

    @Test("A file nested 900 deep attaches a hundred times, each read on a thread with DuckDB's stack")
    func deepFileAttachesRepeatedly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-reattach-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)

        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY)")
        let tables = try await driver.execute(query: "SELECT table_name FROM duckdb_tables() WHERE database_name = 'deep'")
        _ = try await driver.execute(query: "DETACH deep")
        for _ in 0..<100 {
            _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY)")
            _ = try await driver.execute(query: "DETACH deep")
        }
        let threads = try await threadCounts(driver)
        try await driver.disconnect()

        let count = String(ProcessInfo.processInfo.processorCount)
        #expect(tables.rows == [["t"]])
        #expect(threads == [[count, count]])
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

        let driver = try await connectedDuckDB()
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
            counts += try await threadCounts(driver)
        }
        let lowering = await #expect(throws: (any Error).self) {
            try await driver.execute(query: "SET threads = \(base)")
        }
        try await driver.disconnect()

        let raised = [base + 8, base + 16, base + 24].map { [String($0), String($0)] as [String?] }
        #expect(counts == raised)
        #expect(lowering?.localizedDescription.contains("external threads") == true)
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

        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "IMPORT DATABASE '\(folder.path)'")
        for _ in 0..<20 {
            _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY)")
            _ = try await driver.execute(query: "DETACH deep")
        }
        let counts = try await threadCounts(driver)
        try await driver.disconnect()

        #expect(counts == [[raised, raised]])
    }

    @Test("A locked configuration keeps DuckDB's tasks on threads with its stack")
    func lockedConfigurationKeepsTheThreads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duckdb-deep-locked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await deepFile(in: directory)

        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "SET lock_configuration = true")
        for _ in 0..<20 {
            _ = try await driver.execute(query: "ATTACH '\(file.path)' AS deep (READ_ONLY)")
            _ = try await driver.execute(query: "DETACH deep")
        }
        let counts = try await threadCounts(driver)
        try await driver.disconnect()

        let all = String(ProcessInfo.processInfo.processorCount)
        #expect(counts == [[all, all]])
    }

    @Test("A SET that fails for another reason runs once")
    func failedSetRunsOnce() async throws {
        let driver = try await connectedDuckDB()
        _ = try await driver.execute(query: "CREATE SEQUENCE seq")
        await #expect(throws: (any Error).self) {
            try await driver.execute(
                query: "SET VARIABLE x = CASE WHEN nextval('seq') = 1 THEN error('fails once') ELSE 42 END"
            )
        }
        let current = try await driver.execute(query: "SELECT currval('seq')")
        try await driver.disconnect()

        #expect(current.rows == [["1"]])
    }
}
