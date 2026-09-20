//
//  AutocommitOnlyStatement.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

/// Whether the engine refuses this statement, or silently ignores it, inside a transaction block.
///
/// Measured rather than guessed: PostgreSQL answers "VACUUM cannot run inside a transaction block",
/// SQLite "cannot VACUUM from within a transaction", MySQL `ERROR 1694` on the `SET
/// @@SESSION.SQL_LOG_BIN = 0` a GTID mysqldump writes on line 18, DuckDB "Cannot CHECKPOINT", and
/// SQLite applies `PRAGMA foreign_keys = ON` inside one and reads back `0` afterwards with no error
/// at all. Run on its own each of them works, because a single statement is never wrapped.
///
/// A batch holding one runs in autocommit. The rules are per engine family and not per dialect,
/// because the lexing dialect files DuckDB with SQLite and their answers differ.
///
/// A family the app cannot open a transaction on at all answers `false` for every statement,
/// because "refused inside a transaction block" has no meaning where there is never a block.
/// ``BatchTransactionPolicy`` decides those families before it reads a statement.
internal enum AutocommitOnlyStatement {
    internal static func matches(
        _ statement: String,
        family: TransactionEngineFamily,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        matches(statement as NSString, family: family, grammar: grammar)
    }

    internal static func matches(
        _ statement: NSString,
        family: TransactionEngineFamily,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        switch family {
        case .postgres, .redshift, .cockroach:
            return matchesPostgresFamily(statement, family: family, grammar: grammar)
        case .mysql:
            return matchesMySQLFamily(statement, grammar: grammar)
        case .sqlite:
            return matchesSQLite(statement, grammar: grammar)
        case .duckdb:
            return matchesDuckDB(statement, grammar: grammar)
        case .sqlServer:
            return matchesSQLServer(statement, grammar: grammar)
        case .redis, .other:
            return false
        }
    }
}
