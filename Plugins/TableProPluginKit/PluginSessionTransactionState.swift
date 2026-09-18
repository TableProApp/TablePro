//
//  PluginSessionTransactionState.swift
//  TableProPluginKit
//

import Foundation

/// What the session a driver is holding has open right now, for a caller deciding whether it may
/// open, commit or roll back a transaction of its own on it.
///
/// The app runs the editor's statements on the connection's shared session, so a `BEGIN` typed into
/// the editor, a `SET autocommit = 0`, a `LOCK TABLES` or an MCP client's `begin` is still in force
/// when the next multi-statement run arrives. Measured across eight engines, an app-owned
/// `BEGIN`/`COMMIT`/`ROLLBACK` sent over one of those either commits the user's work
/// (MySQL, MariaDB, TiDB, PostgreSQL), discards it (PostgreSQL, SQL Server) or aborts the whole
/// transaction (DuckDB, CockroachDB). This is the question that stops it.
///
/// Every ambiguity resolves toward `.unknown`, which means "decide as if you had not asked": a
/// driver that cannot read its session's state must not report `.idle`, because that is the one
/// answer that lets a caller open a transaction over the user's.
public enum PluginSessionTransactionState: Sendable, Equatable {
    /// No transaction is open and the session holds nothing that opening one would disturb. The
    /// session's commit mode may still be manual; nothing is pending either way, so a caller's own
    /// transaction commits only its own statements.
    case idle

    /// A transaction is open. Committing or rolling it back belongs to whoever opened it.
    case inTransaction

    /// A transaction is open and the engine will accept nothing but a rollback: PostgreSQL's
    /// `PQTRANS_INERROR`, DuckDB's `DUCKDB_ERROR_TRANSACTION`, SQL Server's `XACT_STATE() = -1`.
    /// Measured on PostgreSQL 17.11, a `COMMIT` here answers with the command tag `ROLLBACK` and no
    /// error, so a caller that tells the user to commit loses their work while reporting success.
    case abortedTransaction

    /// No transaction, but the session holds a lock that opening one would release. Measured on
    /// MySQL 5.5.62, 8.4.11, MariaDB 5.5.64 and 11.4.13: a `START TRANSACTION` releases the tables
    /// a `LOCK TABLES` held, and the status flags never show the lock.
    case holdsSessionLocks

    /// The driver cannot tell. Either it has no way to ask, or the read failed.
    case unknown
}
