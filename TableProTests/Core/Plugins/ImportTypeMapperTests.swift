//
//  ImportTypeMapperTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ImportTypeMapperTests {
    @Test("PostgreSQL maps inferred types to native SQL types")
    func testPostgres() {
        #expect(ImportTypeMapper.sqlType(for: .integer, databaseType: .postgresql) == "BIGINT")
        #expect(ImportTypeMapper.sqlType(for: .real, databaseType: .postgresql) == "DOUBLE PRECISION")
        #expect(ImportTypeMapper.sqlType(for: .boolean, databaseType: .postgresql) == "BOOLEAN")
        #expect(ImportTypeMapper.sqlType(for: .json, databaseType: .postgresql) == "JSONB")
        #expect(ImportTypeMapper.sqlType(for: .text, databaseType: .postgresql) == "TEXT")
    }

    @Test(
        "A JSON field on PostgreSQL takes the richest type the server has",
        arguments: [
            (Optional<String>.none, "JSONB"),
            (Optional("17.11"), "JSONB"),
            (Optional("9.4.26"), "JSONB"),
            (Optional("9.3.25"), "JSON"),
            (Optional("9.2.23"), "JSON"),
            (Optional("9.1.24"), "TEXT")
        ]
    )
    func postgresJSONFollowsServerVersion(serverVersion: String?, expected: String) {
        #expect(
            ImportTypeMapper.sqlType(for: .json, databaseType: .postgresql, serverVersion: serverVersion) == expected
        )
    }

    @Test("Redshift and CockroachDB keep their JSON mapping whatever version they report")
    func postgresForksKeepJSONMapping() {
        #expect(ImportTypeMapper.sqlType(for: .json, databaseType: .redshift, serverVersion: "8.0.2") == "JSONB")
        #expect(ImportTypeMapper.sqlType(for: .json, databaseType: .cockroachdb, serverVersion: "13.0.0") == "JSONB")
    }

    @Test("MySQL maps inferred types to native SQL types")
    func testMySQL() {
        #expect(ImportTypeMapper.sqlType(for: .integer, databaseType: .mysql) == "BIGINT")
        #expect(ImportTypeMapper.sqlType(for: .boolean, databaseType: .mysql) == "TINYINT(1)")
        #expect(ImportTypeMapper.sqlType(for: .json, databaseType: .mysql) == "JSON")
    }

    @Test("SQLite uses its storage classes")
    func testSQLite() {
        #expect(ImportTypeMapper.sqlType(for: .integer, databaseType: .sqlite) == "INTEGER")
        #expect(ImportTypeMapper.sqlType(for: .real, databaseType: .sqlite) == "REAL")
        #expect(ImportTypeMapper.sqlType(for: .json, databaseType: .sqlite) == "TEXT")
    }

    @Test("Oracle gets types it has, never TEXT")
    func oracleMapsToItsOwnTypes() {
        #expect(ImportTypeMapper.sqlType(for: .integer, databaseType: .oracle) == "NUMBER(19)")
        #expect(ImportTypeMapper.sqlType(for: .real, databaseType: .oracle) == "BINARY_DOUBLE")
        #expect(ImportTypeMapper.sqlType(for: .text, databaseType: .oracle) == "VARCHAR2(4000 CHAR)")
        #expect(ImportTypeMapper.sqlType(for: .json, databaseType: .oracle) == "CLOB")
    }

    @Test("An Oracle boolean is BOOLEAN from 23ai and the file's own words before it")
    func oracleBooleanFollowsTheRelease() {
        let banners: [(banner: String?, expected: String)] = [
            ("Oracle Database 23ai Free Release 23.0.0.0.0 - Develop, Access, Validate - Production", "BOOLEAN"),
            ("Oracle AI Database 26ai Enterprise Edition Release 23.26.0.0", "BOOLEAN"),
            ("Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production", "VARCHAR2(5 CHAR)"),
            ("Oracle Database 11g Enterprise Edition Release 11.2.0.4.0 - 64bit Production", "VARCHAR2(5 CHAR)"),
            (nil, "VARCHAR2(5 CHAR)")
        ]
        for (banner, expected) in banners {
            #expect(
                ImportTypeMapper.sqlType(for: .boolean, databaseType: .oracle, serverVersion: banner) == expected,
                "\(banner ?? "no banner")"
            )
        }
    }

    @Test("The Oracle release is read from the banner's Release field")
    func oracleReleaseFromBanner() {
        #expect(ImportTypeMapper.oracleMajorRelease(in: "Oracle Database 21c Express Edition Release 21.0.0.0.0") == 21)
        #expect(ImportTypeMapper.oracleMajorRelease(in: "Oracle Database 19c") == nil)
        #expect(ImportTypeMapper.oracleMajorRelease(in: nil) == nil)
    }

    @Test("Unhandled database types fall back to generic SQL types")
    func testFallback() {
        #expect(ImportTypeMapper.sqlType(for: .text, databaseType: .clickhouse) == "TEXT")
        #expect(ImportTypeMapper.sqlType(for: .integer, databaseType: .clickhouse) == "INTEGER")
        #expect(ImportTypeMapper.sqlType(for: .boolean, databaseType: .clickhouse) == "BOOLEAN")
    }
}
