//
//  CompareSQLLiteralTests.swift
//  TableProTests
//
//  The PluginKit default renders binary as `X'89504E47'`, a bit-string literal. MySQL, MariaDB,
//  SQLite and ClickHouse accept it. PostgreSQL rejects it with "column is of type bytea but
//  expression is of type bit", SQL Server wants `0x`, and Oracle wants `HEXTORAW`. No shipped
//  driver overrides `sqlLiteral(for:)`, so the spelling is decided per engine here.
//

import Foundation
@testable import TablePro
import Testing

struct CompareSQLLiteralTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    @Test
    func bitStringEnginesKeepTheDefaultSpelling() throws {
        for type in [DatabaseType.mysql, .mariadb, .tidb, .databend, .oceanbase, .sqlite, .clickhouse, .libsql, .turso, .cloudflareD1] {
            let literal = try #require(CompareSQLLiteral.binaryLiteral(for: png, databaseType: type))
            #expect(literal == "X'89504E47'", "\(type.rawValue) uses a bit-string literal")
        }
    }

    @Test
    func duckDBDecodesHexWithUnhex() throws {
        let literal = try #require(CompareSQLLiteral.binaryLiteral(for: png, databaseType: .duckdb))
        #expect(literal == "unhex('89504E47')")
    }

    /// A compare script runs its own statements, so a plain literal on a SQL Server database with
    /// a non-Unicode collation writes `?` into the target rather than the text it compared.
    @Test
    func textLiteralsCarryTheSQLServerPrefix() {
        #expect(CompareSQLLiteral.prefixed("'日本語'", databaseType: .mssql) == "N'日本語'")
        #expect(CompareSQLLiteral.prefixed("'abc'", databaseType: .mysql) == "'abc'")
    }

    /// `sqlLiteral(for:)` answers `NULL` for a null and passes a number through unquoted. `N` in
    /// front of either is a syntax error.
    @Test
    func onlyQuotedLiteralsTakeThePrefix() {
        #expect(CompareSQLLiteral.prefixed("NULL", databaseType: .mssql) == "NULL")
        #expect(CompareSQLLiteral.prefixed("42", databaseType: .mssql) == "42")
        #expect(CompareSQLLiteral.prefixed("0x89504E47", databaseType: .mssql) == "0x89504E47")
    }

    @Test
    func postgresFamilyUsesAByteaCast() throws {
        for type in [DatabaseType.postgresql, .cockroachdb, .redshift, .pglite, .kingbasees] {
            let literal = try #require(CompareSQLLiteral.binaryLiteral(for: png, databaseType: type))
            #expect(literal == "'\\x89504e47'::bytea", "\(type.rawValue) uses a bytea literal")
        }
    }

    @Test
    func sQLServerUsesZeroX() throws {
        let literal = try #require(CompareSQLLiteral.binaryLiteral(for: png, databaseType: .mssql))

        #expect(literal == "0x89504E47")
    }

    @Test
    func oracleUsesHexToRaw() throws {
        let literal = try #require(CompareSQLLiteral.binaryLiteral(for: png, databaseType: .oracle))

        #expect(literal == "HEXTORAW('89504E47')")
    }

    /// An engine this build does not name falls back to the driver's own spelling rather than
    /// guessing at one, which is why the helper returns nil instead of a default.
    @Test
    func anUnnamedEngineHasNoOpinion() {
        #expect(CompareSQLLiteral.binaryLiteral(for: png, databaseType: DatabaseType(rawValue: "Whatever")) == nil)
    }

    @Test
    func emptyDataStillProducesAValidLiteral() throws {
        let literal = try #require(CompareSQLLiteral.binaryLiteral(for: Data(), databaseType: .postgresql))

        #expect(literal == "'\\x'::bytea")
    }
}
