//
//  DuckDBSafeModeReadOnlyTests.swift
//  TableProMobileTests
//
//  Plugins/DuckDBDriverPlugin/DuckDBReadOnlyStatement.swift, compiled into this target: the Mac plugin is a registry
//  plugin with no test bundle of its own.
//

import CDuckDB
import Foundation
import TableProPluginKit
import Testing

struct DuckDBSafeModeReadOnlyTests {
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

    @Test("An external read names external clients, Read-Only from any origin names Safe Mode, an app read alone neither")
    func reasonFollowsTheContext() {
        var externalRead = PluginStatementContext()
        externalRead.readOnly = true
        externalRead.origin = .external
        var externalSafeModeRead = externalRead
        externalSafeModeRead.enforcesReadOnly = true
        var externalWrite = PluginStatementContext()
        externalWrite.origin = .external
        externalWrite.enforcesReadOnly = true
        var catalogRead = PluginStatementContext()
        catalogRead.readOnly = true
        catalogRead.readsCatalog = true

        #expect(DuckDBReadOnlyStatement.reason(for: externalRead) == .externalClients)
        #expect(DuckDBReadOnlyStatement.reason(for: externalSafeModeRead) == .externalClients)
        #expect(DuckDBReadOnlyStatement.reason(for: PluginStatementContext(enforcesReadOnly: true)) == .safeMode)
        #expect(DuckDBReadOnlyStatement.reason(for: externalWrite) == .safeMode)
        #expect(DuckDBReadOnlyStatement.reason(for: catalogRead) == nil)
        #expect(DuckDBReadOnlyStatement.reason(for: PluginStatementContext()) == nil)
    }

    @Test("At Read-Only a write is refused inside the read-only transaction, and the table keeps its rows")
    func safeModeRefusesWrites() throws {
        let session = try Session()

        for sql in ["INSERT INTO kept VALUES (2)", "UPDATE kept SET a = 5", "CREATE TABLE added (a INTEGER)"] {
            #expect(throws: Refused.self, "\(sql)") {
                try DuckDBReadOnlyStatement.run(on: try session.handle, session: .idle, reason: .safeMode) {
                    try session.run(sql)
                }
            }
        }
        let read = try DuckDBReadOnlyStatement.run(on: try session.handle, session: .idle, reason: .safeMode) {
            session.holds(1)
        }

        #expect(read)
        try session.run("INSERT INTO kept VALUES (3)")
        #expect(session.holds(2))
    }

    @Test(
        "At Read-Only a session not known to be idle is refused before anything runs, naming Safe Mode",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .unknown]
    )
    func safeModeRefusesUnlessIdle(state: PluginSessionTransactionState) throws {
        let session = try Session()
        try session.run("BEGIN TRANSACTION")
        try session.run("INSERT INTO kept VALUES (500)")

        var ran = false
        #expect(throws: DuckDBReadOnlyStatement.Refusal.safeModeTransactionOpen) {
            try DuckDBReadOnlyStatement.run(on: try session.handle, session: state, reason: .safeMode) { ran = true }
        }

        #expect(!ran)
        #expect(
            DuckDBReadOnlyStatement.Refusal.safeModeTransactionOpen.pluginErrorMessage
                != DuckDBReadOnlyStatement.Refusal.transactionOpen.pluginErrorMessage
        )
        try session.run("COMMIT")
        #expect(session.holds(2))
    }
}
