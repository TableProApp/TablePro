//
//  DuckDBPreparedRun.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation
import TableProSQLGrammar

// DuckDB 2.0 prepares through a PREPARE statement that never writes. A binding that does, as nextval() in a SET value
// or a table function's argument does, fails the commit of the prepare's own transaction and invalidates the database
// (core/docs/decisions/0040-duckdb-prepares-inside-a-transaction-it-runs-in.md). Both apps prepare a statement only
// inside a transaction it then runs in.
nonisolated enum DuckDBPreparedRun {
    // The first words of a statement DuckDB prepares as a SELECT, the one kind whose result streams. Any other
    // statement without parameters runs through duckdb_query, which prepares nothing.
    static let streamedKeywords: Set<String> = ["SELECT", "WITH", "FROM", "VALUES", "TABLE", "UNPIVOT"]

    private static let grammar = SQLLexicalReadings.resolve(
        databaseTypeId: "DuckDB", declared: nil, session: nil
    ).execution

    static func streams(_ sql: String) -> Bool {
        guard let keyword = SQLStatementRowLimit.leadingKeyword(sql, grammar: grammar) else { return false }
        return streamedKeywords.contains(keyword)
    }

    // Only on a session known to hold no transaction: a BEGIN inside one aborts it. Returns the failure.
    static func begin(on connection: duckdb_connection) -> String? {
        send("BEGIN TRANSACTION", on: connection)
    }

    // A failed COMMIT is followed by a ROLLBACK, so the session never keeps the transaction. Returns the failure.
    static func commit(on connection: duckdb_connection) -> String? {
        guard let failure = send("COMMIT", on: connection) else { return nil }
        rollback(on: connection)
        return failure
    }

    static func rollback(on connection: duckdb_connection) {
        _ = send("ROLLBACK", on: connection)
    }

    private static func send(_ sql: String, on connection: duckdb_connection) -> String? {
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_query(connection, sql, &result) == DuckDBError else { return nil }
        return duckdb_result_error(&result).map { String(cString: $0) } ?? "DuckDB refused \(sql)"
    }
}
