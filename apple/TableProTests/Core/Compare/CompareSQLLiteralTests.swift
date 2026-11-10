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
import TableProPluginKit
import Testing

private final class NoBackslashEscapesDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }
    var sessionLexicalState: PluginSessionLexicalState? {
        PluginSessionLexicalState(determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes], enabled: [])
    }
}

struct CompareSQLLiteralTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    // The script is also copied and saved with no mode declared: spelled for the session, `x\` would end its literal
    // when it runs in the default mode.
    @Test
    func mysqlTextKeepsItsOwnSetUnderNoBackslashEscapes() {
        let literal = CompareSQLLiteral.textLiteral(
            "x\\", columnType: nil, databaseType: .mysql, driver: NoBackslashEscapesDriver()
        )
        #expect(literal == #"'x\\'"#)
    }

    @Test
    func mysqlKeyLookupUsesTheSessionsEscapes() {
        let literal = CompareSQLLiteral.textLiteral(
            "x\\", columnType: nil, databaseType: .mysql, driver: NoBackslashEscapesDriver(), keptInScript: false
        )
        #expect(literal == #"'x\'"#)
    }

    // Quoted, MySQL stores and compares a BIT value as its characters' bytes, so a synced 5 lands as 53.
    @Test
    func mysqlBitIsWrittenAsItsNumber() {
        let driver = NoBackslashEscapesDriver()
        let bit = ColumnType.boolean(rawType: "bit(8)")
        for type in [DatabaseType.mysql, .mariadb] {
            #expect(CompareSQLLiteral.textLiteral("5", columnType: bit, databaseType: type, driver: driver) == "5")
            #expect(CompareSQLLiteral.literal(
                for: .text("170"), columnType: bit, databaseType: type, driver: driver, keptInScript: false
            ) == "170")
        }
        #expect(CompareSQLLiteral.textLiteral("abc", columnType: bit, databaseType: .mysql, driver: driver) == "'abc'")
        #expect(CompareSQLLiteral.textLiteral("+5", columnType: bit, databaseType: .mysql, driver: driver) == "'+5'")
    }

    @Test
    func otherBooleansAndBitStringsStayQuoted() {
        let driver = NoBackslashEscapesDriver()
        let tinyint = ColumnType.boolean(rawType: "tinyint(1)")
        #expect(CompareSQLLiteral.textLiteral("1", columnType: tinyint, databaseType: .mysql, driver: driver) == "'1'")
        let bit = ColumnType.boolean(rawType: "bit(8)")
        #expect(CompareSQLLiteral.textLiteral("5", columnType: bit, databaseType: .postgresql, driver: driver) != "5")
    }

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
