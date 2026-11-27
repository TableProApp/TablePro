//
//  SQLiteLocalBackendTests.swift
//  SQLiteDriverTests
//

import CSQLite
import Foundation
import os
import TableProPluginKit
import TableProTestSupport
import Testing

private func withDriver(
    openFlags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
    _ body: (SQLitePluginDriver, URL) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-local-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let driver = SQLitePluginDriver(
        config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: url.path),
        backend: SQLiteLocalBackend(path: url.path, openFlags: openFlags)
    )
    try await driver.connect()
    try await body(driver, url)
    await driver.close()
}

private func fillCounting(_ driver: SQLitePluginDriver, to count: Int) async throws {
    _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER)")
    _ = try await driver.execute(query: """
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < \(count)) INSERT INTO t SELECT x FROM n
        """)
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHeader: PluginStreamHeader?
    private var storedBatches: [[[String]]] = []

    var header: PluginStreamHeader? { lock.withLock { storedHeader } }
    var batches: [[[String]]] { lock.withLock { storedBatches } }

    func take(_ header: PluginStreamHeader) {
        lock.withLock { storedHeader = header }
    }

    func take(_ batch: [[String]]) -> Bool {
        lock.withLock { storedBatches.append(batch) }
        return true
    }
}

struct SQLiteBindingTests {
    @Test("An empty binary value binds an empty blob, never NULL")
    func emptyBytesBindAnEmptyBlob() async throws {
        try await withDriver { driver, _ in
            _ = try await driver.execute(query: "CREATE TABLE t (b BLOB)")
            _ = try await driver.executeParameterized(query: "INSERT INTO t VALUES (?)", parameters: [.bytes(Data())])
            let stored = try await driver.execute(query: "SELECT typeof(b), length(b) FROM t").rows

            #expect(stored.first?.map { cell in cell.asText } == ["blob", "0"])
        }
    }

    @Test("A value list that does not match the statement's placeholders is refused and writes nothing", arguments: [1, 3])
    func mismatchedValuesAreRefused(count: Int) async throws {
        try await withDriver { driver, _ in
            _ = try await driver.execute(query: "CREATE TABLE t (a TEXT, b TEXT)")
            let values = Array(repeating: PluginCellValue.text("x"), count: count)

            await #expect(throws: SQLitePluginError.self) {
                _ = try await driver.executeParameterized(query: "INSERT INTO t VALUES (?, ?)", parameters: values)
            }
            let stored = try await driver.execute(query: "SELECT count(*) FROM t").rows
            #expect(stored.first?.first?.asText == "0")
        }
    }

    @Test("A statement handed no values leaves its placeholders NULL")
    func noValuesLeavePlaceholdersNull() async throws {
        try await withDriver { driver, _ in
            let result = try await driver.executeParameterized(query: "SELECT ? IS NULL", parameters: [])

            #expect(result.rows.first?.first?.asText == "1")
        }
    }

    @Test("Text of only comments runs as an empty result, read whole or streamed")
    func commentOnlyTextIsEmpty() async throws {
        try await withDriver { driver, _ in
            let whole = try await driver.execute(query: "-- nothing to run")
            var elements: [PluginStreamElement] = []
            for try await element in driver.streamRows(query: "/* nothing */") {
                elements.append(element)
            }

            #expect(whole.columns.isEmpty)
            #expect(whole.rows.isEmpty)
            #expect(elements.count == 1)
            guard case .header(let header) = elements.first else {
                Issue.record("expected a header alone, got \(elements)")
                return
            }
            #expect(header.columns.isEmpty)
        }
    }
}

struct SQLiteCappedParameterReadTests {
    // Row 5 fails to compute, so a read that steps past the cap's one extra row throws instead of returning.
    @Test("A capped read with parameters takes at most one step past its cap and reports truncated")
    func cappedReadStopsAtItsCap() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 10_000)
            let result = try await driver.executeUserQuery(
                query: "SELECT id, json_extract(CASE WHEN id > CAST(? AS INTEGER) THEN 'not json' ELSE '1' END, '$') FROM t",
                rowCap: 3,
                parameters: [.text("4")]
            )

            #expect(result.rows.count == 3)
            #expect(result.isTruncated)
            #expect(result.rows.last?.first?.asText == "3")
        }
    }

    @Test("A capped WITH ... DELETE ... RETURNING with parameters deletes every row it names")
    func cappedReturningDeletesEveryRow() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 50)
            let result = try await driver.executeUserQuery(
                query: """
                    WITH doomed AS (SELECT id FROM t WHERE id > CAST(? AS INTEGER))
                    DELETE FROM t WHERE id IN (SELECT id FROM doomed) RETURNING id
                    """,
                rowCap: 3,
                parameters: [.text("0")]
            )
            let left = try await driver.execute(query: "SELECT count(*) FROM t").rows

            #expect(result.rows.count == 3)
            #expect(result.isTruncated)
            #expect(left.first?.first?.asText == "0")
        }
    }

    // A write commits, and checks a deferred key, only at its last step, so a capped one has to get there.
    @Test("A capped write that returns rows runs to its end, so a deferred key it breaks fails it and nothing stays")
    func cappedWriteMeetsItsDeferredKey() async throws {
        try await withDriver { driver, _ in
            _ = try await driver.execute(query: "PRAGMA foreign_keys = ON")
            _ = try await driver.execute(query: "CREATE TABLE parent (id INTEGER PRIMARY KEY)")
            _ = try await driver.execute(query: """
                CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent (id) DEFERRABLE INITIALLY DEFERRED)
                """)

            await #expect(throws: (any Error).self) {
                _ = try await driver.executeUserQuery(
                    query: """
                        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 10)
                        INSERT INTO child (id, parent_id) SELECT x, CAST(? AS INTEGER) FROM n RETURNING id
                        """,
                    rowCap: 3,
                    parameters: [.text("99")]
                )
            }
            let left = try await driver.execute(query: "SELECT count(*) FROM child").rows
            #expect(left.first?.first?.asText == "0")
        }
    }

    @Test("A read with parameters and no cap reads every row, and a capped write reports every row it changed")
    func uncappedReadAndCappedWriteRunWhole() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 10_000)
            let read = try await driver.executeUserQuery(
                query: "SELECT id FROM t WHERE id > CAST(? AS INTEGER)", rowCap: nil, parameters: [.text("0")]
            )
            let write = try await driver.executeUserQuery(
                query: "UPDATE t SET id = id + 0 WHERE id > CAST(? AS INTEGER)", rowCap: 3, parameters: [.text("0")]
            )

            #expect(read.rows.count == 10_000)
            #expect(!read.isTruncated)
            #expect(write.rowsAffected == 10_000)
        }
    }
}

struct SQLiteOpenFlagTests {
    @Test("A read-only open reads the file and refuses a write")
    func readOnlyOpenRefusesWrites() async throws {
        try await withDriver { writer, url in
            _ = try await writer.execute(query: "CREATE TABLE t (id INTEGER)")
            _ = try await writer.execute(query: "INSERT INTO t VALUES (1)")
            let reader = SQLitePluginDriver(
                config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: url.path),
                backend: SQLiteLocalBackend(path: url.path, openFlags: SQLITE_OPEN_READONLY)
            )
            try await reader.connect()

            let count = try await reader.execute(query: "SELECT count(*) FROM t").rows
            await #expect(throws: SQLitePluginError.self) {
                _ = try await reader.execute(query: "INSERT INTO t VALUES (2)")
            }
            await reader.close()
            #expect(count.first?.first?.asText == "1")
        }
    }

    @Test("An open that may not create fails on a missing file and creates nothing")
    func openWithoutCreateLeavesNoFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-missing-\(UUID().uuidString)")
        let missing = folder.appendingPathComponent("gone.sqlite")
        let driver = SQLitePluginDriver(
            config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: missing.path),
            backend: SQLiteLocalBackend(path: missing.path, openFlags: SQLITE_OPEN_READWRITE)
        )

        await #expect(throws: SQLitePluginError.self) { try await driver.connect() }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let state = await driver.sessionTransactionState()
        #expect(state == .unknown)
    }
}

struct SQLiteValueReadTests {
    private static let text: SQLiteValueReader<String> = { column, value in
        switch value {
        case .null: "\(column)=null"
        case .text(let utf8): "\(column)=\(String(decoding: utf8, as: UTF8.self))"
        case .bytes(let bytes): "\(column)=\(bytes.count) bytes"
        }
    }

    @Test("A read hands each value over in place, a batch at a time, and stops at its row limit")
    func valuesArriveInBatchesUpToTheLimit() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 1_200)
            let collected = Collected()
            try await driver.readValues(
                query: "SELECT id, zeroblob(3) AS b FROM t ORDER BY id",
                context: PluginStatementContext(),
                rowLimit: 1_001,
                reading: Self.text,
                header: { collected.take($0) },
                deliver: { collected.take($0) }
            )
            let next = try await driver.execute(query: "SELECT count(*) FROM t").rows

            #expect(collected.header?.columns == ["id", "b"])
            #expect(collected.batches.map { batch in batch.count } == [500, 500, 1])
            #expect(collected.batches.first?.first == ["id=1", "b=3 bytes"])
            #expect(collected.batches.last?.last == ["id=1001", "b=3 bytes"])
            #expect(next.first?.first?.asText == "1200")
        }
    }

    @Test("A read that reached its row limit takes no further step", .timeLimit(.minutes(1)))
    func limitTakesNoFurtherStep() async throws {
        try await withDriver { driver, _ in
            let collected = Collected()
            try await driver.readValues(
                query: "SELECT 1 UNION ALL SELECT (WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c)",
                context: PluginStatementContext(),
                rowLimit: 1,
                reading: Self.text,
                header: { collected.take($0) },
                deliver: { collected.take($0) }
            )

            #expect(collected.batches.flatMap { $0 } == [["1=1"]])
        }
    }

    @Test("Rows read before a failing row arrive before the failure")
    func rowsBeforeAFailureArrive() async throws {
        try await withDriver { driver, _ in
            _ = try await driver.execute(query: "CREATE TABLE j (id INTEGER PRIMARY KEY, doc TEXT)")
            _ = try await driver.execute(query: """
                INSERT INTO j VALUES (1, '{"a":1}'), (2, '{"a":2}'), (3, 'not json'), (4, '{"a":4}')
                """)
            let collected = Collected()

            await #expect(throws: SQLitePluginError.self) {
                try await driver.readValues(
                    query: "SELECT id, json_extract(doc, '$.a') FROM j ORDER BY id",
                    context: PluginStatementContext(),
                    rowLimit: .max,
                    reading: Self.text,
                    header: { collected.take($0) },
                    deliver: { collected.take($0) }
                )
            }
            #expect(collected.batches.flatMap { $0 }.count == 2)
        }
    }

    @Test("A statement whose caller was cancelled before the connection took it runs nothing")
    func cancelledCallerRunsNothing() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 3)
            let write = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await driver.readValues(
                    query: "DELETE FROM t",
                    context: PluginStatementContext(),
                    rowLimit: .max,
                    reading: Self.text,
                    header: { _ in },
                    deliver: { _ in true }
                )
            }
            let outcome = await write.result
            let count = try await driver.execute(query: "SELECT count(*) FROM t").rows

            #expect(throws: CancellationError.self) { try outcome.get() }
            #expect(count.first?.first?.asText == "3")
        }
    }

    @Test("A statement with no columns reports the rows it changed")
    func commandReportsChangedRows() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 7)
            let changed = try await driver.readValues(
                query: "DELETE FROM t WHERE id > 4",
                context: PluginStatementContext(),
                rowLimit: .max,
                reading: Self.text,
                header: { _ in },
                deliver: { _ in true }
            )

            #expect(changed == 3)
        }
    }
}

struct SQLitePulledReadTests {
    @Test("A pulled read lets other statements run between its batches and reads every row")
    func statementsRunBetweenBatches() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 1_200)
            var iterator = driver.pulledRows(query: "SELECT id FROM t ORDER BY id", context: PluginStatementContext())
                .makeAsyncIterator()
            var rows: [PluginRow] = []
            var beside: [String?] = []
            while let element = try await iterator.next() {
                if case .rows(let batch) = element { rows += batch }
                beside.append(try await driver.execute(query: "SELECT 42").rows.first?.first?.asText)
            }

            #expect(rows.count == 1_200)
            #expect(rows.last == [.text("1200")])
            #expect(beside.count == 4)
            #expect(beside.allSatisfy { $0 == "42" })
        }
    }

    // SQLite refuses to drop a table a statement still reads (SQLITE_LOCKED), so the drop lands once the read is gone.
    @Test("A reader that lets go early finalizes its statement")
    func earlyReleaseFinalizes() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 2_000)
            do {
                var iterator = driver.pulledRows(query: "SELECT id FROM t", context: PluginStatementContext())
                    .makeAsyncIterator()
                _ = try await iterator.next()
                _ = try await iterator.next()
            }

            var dropped = false
            for _ in 0..<200 where !dropped {
                dropped = (try? await driver.execute(query: "DROP TABLE t")) != nil
                if !dropped { try await Task.sleep(for: .milliseconds(10)) }
            }
            #expect(dropped)
        }
    }

    @Test("A Stop with no request running leaves a pulled read whole")
    func idleStopLeavesTheReadWhole() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 1_200)
            var iterator = driver.pulledRows(query: "SELECT id FROM t", context: PluginStatementContext())
                .makeAsyncIterator()
            var rows = 0
            while let element = try await iterator.next() {
                if case .rows(let batch) = element { rows += batch.count }
                try driver.cancelQuery()
            }

            #expect(rows == 1_200)
        }
    }

    // An interrupt stays in effect while any statement is unfinished, and SQLite rolls back the transaction of a write it
    // interrupts.
    @Test("A request stopped while a pulled read holds its statement open leaves the next write in the transaction standing")
    func stopBesideAnOpenReadKeepsTheTransaction() async throws {
        try await withDriver { driver, _ in
            try await fillCounting(driver, to: 2_000)
            _ = try await driver.execute(query: "BEGIN")
            var iterator = driver.pulledRows(query: "SELECT id FROM t", context: PluginStatementContext())
                .makeAsyncIterator()
            _ = try await iterator.next()
            _ = try await iterator.next()

            let finished = OSAllocatedUnfairLock(initialState: false)
            let endless = Task {
                defer { finished.withLock { $0 = true } }
                _ = try await driver.execute(
                    query: "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"
                )
            }
            try await waitUntil {
                try? driver.cancelQuery()
                return finished.withLock { $0 }
            }
            let stopped = await endless.result
            let inserted = try await driver.execute(query: "INSERT INTO t VALUES (0)")
            let state = await driver.sessionTransactionState()
            var readFailed = false
            do {
                _ = try await iterator.next()
            } catch {
                readFailed = true
            }
            _ = try await driver.execute(query: "COMMIT")
            let count = try await driver.execute(query: "SELECT count(*) FROM t").rows

            #expect(throws: (any Error).self) { try stopped.get() }
            #expect(inserted.rowsAffected == 1)
            #expect(state == .inTransaction)
            #expect(readFailed)
            #expect(count.first?.first?.asText == "2001")
        }
    }
}

struct SQLiteLocalBackendThreadTests {
    // Holds the file's exclusive lock on a connection of its own, so every reader waits in the busy handler until the
    // lock goes, as it would for a database another process has locked with the busy timeout at 0.
    private final class Locker: @unchecked Sendable {
        private let lock = NSLock()
        private var db: OpaquePointer?

        init(path: String) throws {
            guard sqlite3_open(path, &db) == SQLITE_OK,
                  sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(db)
                throw SQLitePluginError.queryFailed("could not lock the test database")
            }
        }

        func release() {
            lock.withLock {
                guard let db else { return }
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    @Test("Statements waiting on a locked database, one per core and more, leave the process's other tasks running",
          .timeLimit(.minutes(1)))
    func lockWaitsLeaveTheSharedPoolFree() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-pool-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let config = DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: url.path)
        let setup = SQLitePluginDriver(config: config, backend: SQLiteLocalBackend(path: url.path))
        try await setup.connect()
        _ = try await setup.execute(query: "CREATE TABLE t (id INTEGER)")
        await setup.close()

        let waiters = (0..<(ProcessInfo.processInfo.activeProcessorCount + 2)).map { _ in
            SQLitePluginDriver(config: config, backend: SQLiteLocalBackend(path: url.path))
        }
        for waiter in waiters {
            try await waiter.connect()
        }
        let locker = try Locker(path: url.path)
        let reads = waiters.map { waiter in
            Task { try await waiter.execute(query: "SELECT count(*) FROM t").rows.first?.first?.asText }
        }

        // Ends the waits from a thread outside the pool, so a starved pool still lets the test finish and fail. A queue
        // of its own, since waits that wake every 10 ms on the pool's threads also hold back `DispatchQueue.global()`.
        let releasedByWatchdog = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue(label: "com.TablePro.tests.sqlite-lock-watchdog").asyncAfter(deadline: .now() + 10) {
            releasedByWatchdog.withLock { $0 = true }
            locker.release()
        }
        // Nothing outside SQLite says when every reader is waiting, so other tasks keep running for a while after the
        // readers start: once the waits hold the pool, the next one runs only when the watchdog ends them.
        let probing = ContinuousClock.now
        var probes = 0
        while ContinuousClock.now - probing < .seconds(2), !releasedByWatchdog.withLock({ $0 }) {
            probes += await Task.detached { 1 }.value
        }
        let starved = releasedByWatchdog.withLock { $0 }
        locker.release()

        var counts: [String?] = []
        for read in reads {
            counts.append(try await read.value)
        }
        for waiter in waiters {
            await waiter.close()
        }

        #expect(probes > 0)
        #expect(!starved)
        #expect(counts == Array(repeating: "0", count: waiters.count))
    }
}
