//
//  DuckDBReadOnlyStatementTests.swift
//  TableProMobileTests
//
//  Plugins/DuckDBDriverPlugin/DuckDBReadOnlyStatement.swift, compiled into this target: the Mac plugin is a registry
//  plugin with no test bundle of its own.
//

import CDuckDB
import Foundation
import TableProPluginKit
import Testing

struct DuckDBReadOnlyStatementTests {
    private struct Refused: Error {}

    private final class Session {
        private var database: duckdb_database?
        private var connection: duckdb_connection?

        init() throws {
            guard duckdb_open_ext(nil, &database, nil, nil) != DuckDBError,
                  duckdb_connect(database, &connection) != DuckDBError
            else { throw Refused() }
            try run("CREATE TABLE kept (a INTEGER)")
            try run("INSERT INTO kept VALUES (1)")
        }

        deinit {
            duckdb_disconnect(&connection)
            duckdb_close(&database)
        }

        var handle: duckdb_connection {
            get throws {
                guard let connection else { throw Refused() }
                return connection
            }
        }

        func run(_ sql: String) throws {
            var result = duckdb_result()
            defer { duckdb_destroy_result(&result) }
            guard duckdb_query(try handle, sql, &result) != DuckDBError else { throw Refused() }
        }

        // The CAST fails unless the count matches, so the check needs no value reading.
        func holds(_ rows: Int) -> Bool {
            (try? run("SELECT CAST(CASE WHEN count(*) = \(rows) THEN '1' ELSE 'x' END AS INTEGER) FROM kept")) != nil
        }
    }

    @Test("A read-only statement cannot insert, and the table keeps its rows")
    func insertIsRefused() throws {
        let session = try Session()

        #expect(throws: Refused.self) {
            try DuckDBReadOnlyStatement.run(on: try session.handle, session: .idle) {
                try session.run("INSERT INTO kept VALUES (2)")
            }
        }
        #expect(throws: Refused.self) {
            try DuckDBReadOnlyStatement.run(on: try session.handle, session: .idle) {
                try session.run("CREATE TABLE added (a INTEGER)")
            }
        }

        #expect(session.holds(1))
        try session.run("INSERT INTO kept VALUES (3)")
        #expect(session.holds(2))
    }

    @Test("A read-only SELECT runs, and the session is left with no transaction")
    func readRuns() throws {
        let session = try Session()

        let read = try DuckDBReadOnlyStatement.run(on: try session.handle, session: .idle) { session.holds(1) }
        #expect(read)
        try session.run("BEGIN TRANSACTION")
        try session.run("ROLLBACK")
    }

    @Test("A statement that ends the read-only transaction itself leaves the session usable")
    func statementEndsTransaction() throws {
        let session = try Session()

        try DuckDBReadOnlyStatement.run(on: try session.handle, session: .idle) {
            try session.run("COMMIT")
        }
        try session.run("INSERT INTO kept VALUES (2)")
        #expect(session.holds(2))
    }

    @Test(
        "A session not known to be idle is refused before anything runs, and its transaction survives",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .unknown]
    )
    func openTransactionIsRefused(state: PluginSessionTransactionState) throws {
        let session = try Session()
        try session.run("BEGIN TRANSACTION")
        try session.run("INSERT INTO kept VALUES (500)")

        var ran = false
        #expect(throws: DuckDBReadOnlyStatement.Refusal.transactionOpen) {
            try DuckDBReadOnlyStatement.run(on: try session.handle, session: state) { ran = true }
        }

        #expect(!ran)
        #expect(session.holds(2))
        try session.run("COMMIT")
        #expect(session.holds(2))
    }
}
