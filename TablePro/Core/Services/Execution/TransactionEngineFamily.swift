//
//  TransactionEngineFamily.swift
//  TablePro
//
//  Which engines refuse the same statements inside a transaction block.
//
//  Not the same grouping as `SqlDialect`, which exists to lex a script: that one files DuckDB
//  under `.sqlite` because both take its string literals, and SQL Server under `.generic`. Their
//  transaction rules are unrelated. SQLite refuses `VACUUM` and a `PRAGMA journal_mode` inside a
//  transaction and DuckDB allows both, so reusing the lexing grouping would unwrap every DuckDB
//  batch that vacuums and leave every SQL Server batch that backs up wrapped.
//
//  Curated by name, the `SQLTypeFamily` pattern, because what an engine refuses is a fact about
//  that engine and no capability the plugin registry publishes implies it. `DatabaseType` is open,
//  so anything not named here is `.other` and keeps the wrap it has today.
//

import Foundation

internal enum TransactionEngineFamily: String, Hashable, Sendable, CaseIterable {
    case postgres
    case redshift
    case cockroach
    case mysql
    case sqlite
    case duckdb
    case sqlServer
    case oracle
    case redis
    case other

    internal static func of(_ type: DatabaseType) -> TransactionEngineFamily {
        familiesByTypeId[type.rawValue] ?? .other
    }

    /// Whether the app may open a transaction of its own around a batch.
    ///
    /// Redis `MULTI` does not open one so much as start queueing: every command after it answers
    /// `+QUEUED` in place of its own reply and nothing runs until `EXEC`, which then applies the
    /// whole block and puts each command's failure in its own element of one reply array. So a
    /// wrapped batch reports `QUEUED` for every statement, hides every error, and cannot be rolled
    /// back once `EXEC` has run. Measured on Redis 8.10.1: `MULTI; GET s; LPUSH s x; SET t 1; DEL
    /// nokey; INCR s; EXEC` answers five `+QUEUED` and then an array holding two errors, with
    /// `SET t 1` applied.
    internal var wrapsBatchInTransaction: Bool {
        self != .redis
    }

    /// Whether `SAVEPOINT` opens a transaction of its own, which makes a batch holding one a script
    /// that manages its own transaction rather than one running in autocommit. Measured on SQLite
    /// 3.54.0: `SAVEPOINT a; INSERT ...; BEGIN` answers "cannot start a transaction within a
    /// transaction", and on Oracle 23ai `DBMS_TRANSACTION.LOCAL_TRANSACTION_ID` is set after a
    /// `SAVEPOINT` alone. DuckDB has no `SAVEPOINT` at all, and PostgreSQL rejects one outside a
    /// transaction block instead of opening one.
    internal var savepointOpensTransaction: Bool {
        self == .sqlite || self == .oracle
    }

    /// Whether `SET TRANSACTION` opens a transaction, which makes a batch holding one a script that
    /// manages its own. Measured on Oracle 23ai: `DBMS_TRANSACTION.LOCAL_TRANSACTION_ID` is set
    /// right after it, and the transaction lasts until a `COMMIT` or `ROLLBACK`. Oracle has no
    /// `BEGIN` for a transaction, so this is the statement a script opens one with.
    internal var setTransactionOpensTransaction: Bool {
        self == .oracle
    }

    private static let familiesByTypeId: [String: TransactionEngineFamily] = [
        "PostgreSQL": .postgres,
        "PGlite": .postgres,
        "AlloyDB": .postgres,
        "Citus": .postgres,
        "Greenplum": .postgres,
        "Redshift": .redshift,
        "CockroachDB": .cockroach,
        "MySQL": .mysql,
        "MariaDB": .mysql,
        "TiDB": .mysql,
        "OceanBase": .mysql,
        "SQLite": .sqlite,
        "libSQL": .sqlite,
        "Turso": .sqlite,
        "DuckDB": .duckdb,
        "SQL Server": .sqlServer,
        "Oracle": .oracle,
        "Redis": .redis
    ]
}
