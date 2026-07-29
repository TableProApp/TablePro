//
//  ImportTypeMapperTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Import Type Mapper")
struct ImportTypeMapperTests {
    @Test("PostgreSQL maps inferred types to native SQL types")
    func testPostgres() {
        #expect(ImportTypeMapper.sqlType(for: .integer, databaseType: .postgresql) == "BIGINT")
        #expect(ImportTypeMapper.sqlType(for: .real, databaseType: .postgresql) == "DOUBLE PRECISION")
        #expect(ImportTypeMapper.sqlType(for: .boolean, databaseType: .postgresql) == "BOOLEAN")
        #expect(ImportTypeMapper.sqlType(for: .json, databaseType: .postgresql) == "JSONB")
        #expect(ImportTypeMapper.sqlType(for: .text, databaseType: .postgresql) == "TEXT")
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

    @Test("Unhandled database types fall back to generic SQL types")
    func testFallback() {
        #expect(ImportTypeMapper.sqlType(for: .text, databaseType: .clickhouse) == "TEXT")
        #expect(ImportTypeMapper.sqlType(for: .integer, databaseType: .clickhouse) == "INTEGER")
        #expect(ImportTypeMapper.sqlType(for: .boolean, databaseType: .clickhouse) == "BOOLEAN")
    }
}
