import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

// DuckDB 2.0 invalidates the database when a prepare's own transaction commits what its binding wrote
// (core/docs/decisions/0040-duckdb-prepares-inside-a-transaction-it-runs-in.md).
struct DuckDBSideEffectingBindTests {
    private func connectedDriver() async throws -> DuckDBBackedDriver {
        let driver = DuckDBBackedDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE SEQUENCE seq START 20")
        _ = try await driver.execute(query: "CREATE TABLE t AS SELECT 1 AS a")
        return driver
    }

    private func streamedRowCount(_ driver: DuckDBBackedDriver, _ query: String) async throws -> Int {
        var count = 0
        for try await element in driver.executeStreaming(query: query, options: .default) {
            if case .row = element { count += 1 }
        }
        return count
    }

    @Test("A streamed read whose table function takes a sequence value leaves the database open")
    func streamedReadKeepsTheDatabase() async throws {
        let driver = try await connectedDriver()
        let streamed = try await streamedRowCount(driver, "SELECT * FROM range(nextval('seq'))")
        let after = try await driver.execute(query: "SELECT count(*) FROM t").rows
        let state = await driver.sessionTransactionState()
        try await driver.disconnect()

        #expect(streamed >= 20)
        #expect(after == [["1"]])
        #expect(state == .idle)
    }

    @Test("Inside the user's transaction the read prepares there, and its COMMIT keeps the database open")
    func readInsideTheUsersTransaction() async throws {
        let driver = try await connectedDriver()
        _ = try await driver.execute(query: "BEGIN TRANSACTION")
        _ = try await driver.execute(query: "INSERT INTO t VALUES (2)")
        let streamed = try await streamedRowCount(driver, "SELECT * FROM range(nextval('seq'))")
        let inside = await driver.sessionTransactionState()
        _ = try await driver.execute(query: "COMMIT")
        let after = try await driver.execute(query: "SELECT count(*) FROM t").rows
        try await driver.disconnect()

        #expect(streamed >= 20)
        #expect(inside == .explicitTransaction)
        #expect(after == [["2"]])
    }

    @Test("An export whose table function takes a sequence value leaves the database open")
    func exportKeepsTheDatabase() async throws {
        let driver = try await connectedDriver()
        let opened = try await driver.openTransferDriver()
        let transfer = try #require(opened as? any ExportRowStreaming)
        var rows = 0
        for try await element in transfer.exportRows(query: "SELECT * FROM range(nextval('seq'))", readOnly: false) {
            if case .rows(let batch) = element { rows += batch.count }
        }
        let after = try await driver.execute(query: "SELECT count(*) FROM t").rows
        try await driver.disconnect()

        #expect(rows >= 20)
        #expect(after == [["1"]])
    }

    @Test("A SET whose value takes a sequence value takes it once and leaves the database open")
    func setTakesTheValueOnce() async throws {
        let driver = try await connectedDriver()
        _ = try await driver.execute(query: "SET memory_limit = nextval('seq') || 'GB'")
        let current = try await driver.execute(query: "SELECT currval('seq')").rows
        try await driver.disconnect()

        #expect(current == [["20"]])
    }

    @Test("Only a statement DuckDB prepares as a SELECT streams", arguments: [
        ("SELECT 1", true),
        ("  -- a note\n/* and */ select * from t", true),
        ("(SELECT 1)", true),
        ("WITH x AS (SELECT 1) SELECT * FROM x", true),
        ("FROM t", true),
        ("VALUES (1)", true),
        ("TABLE t", true),
        ("UNPIVOT t ON a INTO NAME k VALUE v", true),
        ("SET threads = nextval('seq')", false),
        ("PRAGMA threads = 4", false),
        ("INSERT INTO t VALUES (1) RETURNING *", false),
        ("CALL range(3)", false),
        ("EXPLAIN SELECT 1", false),
        ("PIVOT t ON a", false),
        ("BEGIN", false),
        ("", false),
    ])
    func streamedStatements(sql: String, streams: Bool) {
        #expect(DuckDBPreparedRun.streams(sql) == streams)
    }
}
