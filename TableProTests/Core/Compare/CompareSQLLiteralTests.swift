//
//  CompareSQLLiteralTests.swift
//  TableProTests
//
//  The PluginKit default renders binary as `X'89504E47'`, a bit-string literal. MySQL, MariaDB,
//  SQLite and ClickHouse accept it. PostgreSQL rejects it with "column is of type bytea but
//  expression is of type bit", SQL Server wants `0x`, and Oracle wants `HEXTORAW`. No shipped
//  driver overrides `sqlLiteral(for:)`, so the spelling is decided per engine here.
//

@testable import TablePro
import XCTest

final class CompareSQLLiteralTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    func testBitStringEnginesKeepTheDefaultSpelling() throws {
        for type in [DatabaseType.mysql, .mariadb, .sqlite, .clickhouse, .duckdb, .libsql, .turso, .cloudflareD1] {
            let literal = try XCTUnwrap(CompareSQLLiteral.binaryLiteral(for: png, databaseType: type))
            XCTAssertEqual(literal, "X'89504E47'", "\(type.rawValue) uses a bit-string literal")
        }
    }

    func testPostgresFamilyUsesAByteaCast() throws {
        for type in [DatabaseType.postgresql, .cockroachdb, .redshift, .pglite] {
            let literal = try XCTUnwrap(CompareSQLLiteral.binaryLiteral(for: png, databaseType: type))
            XCTAssertEqual(literal, "'\\x89504e47'::bytea", "\(type.rawValue) uses a bytea literal")
        }
    }

    func testSQLServerUsesZeroX() throws {
        let literal = try XCTUnwrap(CompareSQLLiteral.binaryLiteral(for: png, databaseType: .mssql))

        XCTAssertEqual(literal, "0x89504E47")
    }

    func testOracleUsesHexToRaw() throws {
        let literal = try XCTUnwrap(CompareSQLLiteral.binaryLiteral(for: png, databaseType: .oracle))

        XCTAssertEqual(literal, "HEXTORAW('89504E47')")
    }

    /// An engine this build does not name falls back to the driver's own spelling rather than
    /// guessing at one, which is why the helper returns nil instead of a default.
    func testAnUnnamedEngineHasNoOpinion() {
        XCTAssertNil(CompareSQLLiteral.binaryLiteral(for: png, databaseType: DatabaseType(rawValue: "Whatever")))
    }

    func testEmptyDataStillProducesAValidLiteral() throws {
        let literal = try XCTUnwrap(CompareSQLLiteral.binaryLiteral(for: Data(), databaseType: .postgresql))

        XCTAssertEqual(literal, "'\\x'::bytea")
    }
}
