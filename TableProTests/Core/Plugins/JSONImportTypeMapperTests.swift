//
//  JSONImportTypeMapperTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("JSON Import Type Mapper")
struct JSONImportTypeMapperTests {
    @Test("PostgreSQL maps inferred types to native SQL types")
    func testPostgres() {
        #expect(JSONImportTypeMapper.sqlType(for: .integer, databaseType: .postgresql) == "BIGINT")
        #expect(JSONImportTypeMapper.sqlType(for: .real, databaseType: .postgresql) == "DOUBLE PRECISION")
        #expect(JSONImportTypeMapper.sqlType(for: .boolean, databaseType: .postgresql) == "BOOLEAN")
        #expect(JSONImportTypeMapper.sqlType(for: .json, databaseType: .postgresql) == "JSONB")
        #expect(JSONImportTypeMapper.sqlType(for: .text, databaseType: .postgresql) == "TEXT")
    }

    @Test("MySQL maps inferred types to native SQL types")
    func testMySQL() {
        #expect(JSONImportTypeMapper.sqlType(for: .integer, databaseType: .mysql) == "BIGINT")
        #expect(JSONImportTypeMapper.sqlType(for: .boolean, databaseType: .mysql) == "TINYINT(1)")
        #expect(JSONImportTypeMapper.sqlType(for: .json, databaseType: .mysql) == "JSON")
    }

    @Test("SQLite uses its storage classes")
    func testSQLite() {
        #expect(JSONImportTypeMapper.sqlType(for: .integer, databaseType: .sqlite) == "INTEGER")
        #expect(JSONImportTypeMapper.sqlType(for: .real, databaseType: .sqlite) == "REAL")
        #expect(JSONImportTypeMapper.sqlType(for: .json, databaseType: .sqlite) == "TEXT")
    }

    @Test("Unhandled database types fall back to generic SQL types")
    func testFallback() {
        #expect(JSONImportTypeMapper.sqlType(for: .text, databaseType: .clickhouse) == "TEXT")
        #expect(JSONImportTypeMapper.sqlType(for: .integer, databaseType: .clickhouse) == "INTEGER")
        #expect(JSONImportTypeMapper.sqlType(for: .boolean, databaseType: .clickhouse) == "BOOLEAN")
    }
}
