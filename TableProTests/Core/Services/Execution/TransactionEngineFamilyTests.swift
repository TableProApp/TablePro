//
//  TransactionEngineFamilyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TransactionEngineFamilyTests {
    @Test(
        "Every PostgreSQL-compatible engine reads the PostgreSQL rules",
        arguments: ["PostgreSQL", "PGlite", "AlloyDB", "Citus", "Greenplum"]
    )
    func postgresCompatibles(typeId: String) {
        #expect(TransactionEngineFamily.of(DatabaseType(rawValue: typeId)) == .postgres)
    }

    @Test("Redshift and CockroachDB add rules of their own, so they are not PostgreSQL")
    func warehousesAreTheirOwnFamilies() {
        #expect(TransactionEngineFamily.of(.redshift) == .redshift)
        #expect(TransactionEngineFamily.of(.cockroachdb) == .cockroach)
    }

    @Test(
        "Every MySQL-protocol engine reads the MySQL rules",
        arguments: ["MySQL", "MariaDB", "TiDB", "OceanBase"]
    )
    func mysqlCompatibles(typeId: String) {
        #expect(TransactionEngineFamily.of(DatabaseType(rawValue: typeId)) == .mysql)
    }

    @Test(
        "Every SQLite-compatible engine reads the SQLite rules",
        arguments: ["SQLite", "libSQL", "Turso"]
    )
    func sqliteCompatibles(typeId: String) {
        #expect(TransactionEngineFamily.of(DatabaseType(rawValue: typeId)) == .sqlite)
    }

    /// The lexing dialect files DuckDB under SQLite and SQL Server under generic. Both would be
    /// wrong here: DuckDB takes `VACUUM` and every `PRAGMA` inside a transaction, and SQL Server has
    /// a restricted list of its own.
    @Test("DuckDB and SQL Server are not SQLite and not generic")
    func lexingDialectIsNotTheAnswer() {
        #expect(TransactionEngineFamily.of(.duckdb) == .duckdb)
        #expect(TransactionEngineFamily.of(.mssql) == .sqlServer)
    }

    @Test(
        "An engine with no curated rules falls back to keeping the wrap",
        arguments: ["Databend", "Cloudflare D1", "Snowflake", "ClickHouse", "MongoDB", "FutureDB"]
    )
    func unknownEnginesFallBack(typeId: String) {
        #expect(TransactionEngineFamily.of(DatabaseType(rawValue: typeId)) == .other)
    }

    @Test("Oracle reads its own rules")
    func oracleIsItsOwnFamily() {
        #expect(TransactionEngineFamily.of(.oracle) == .oracle)
    }

    @Test("Only SQLite and Oracle open a transaction with a savepoint")
    func savepointOpensATransactionOnSQLiteAndOracle() {
        for family in TransactionEngineFamily.allCases {
            #expect(family.savepointOpensTransaction == (family == .sqlite || family == .oracle))
        }
    }

    @Test("Only Oracle opens a transaction with SET TRANSACTION")
    func setTransactionOpensATransactionOnOracleAlone() {
        for family in TransactionEngineFamily.allCases {
            #expect(family.setTransactionOpensTransaction == (family == .oracle))
        }
    }

    @Test("Redis has rules of its own, so it is not the fallback")
    func redisIsItsOwnFamily() {
        #expect(TransactionEngineFamily.of(.redis) == .redis)
    }

    /// Redis is the only engine the app cannot open a transaction on: `MULTI` queues commands until
    /// `EXEC` and answers `+QUEUED` in place of every reply, and `DISCARD` can only drop a queue
    /// nothing has applied.
    @Test("Only Redis refuses the wrap outright")
    func onlyRedisRefusesTheWrap() {
        for family in TransactionEngineFamily.allCases {
            #expect(family.wrapsBatchInTransaction == (family != .redis))
        }
    }
}
