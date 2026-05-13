//
//  TableOperationDialogLogicTests.swift
//  TableProTests
//
//  Tests for TableOperationDialog computed property logic and TableOperationOptions model.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("TableOperationDialog Logic")
struct TableOperationDialogLogicTests {

    // MARK: - Dialog Logic Helper

    private enum DialogLogic {
        static func title(tableName: String, tableCount: Int, operationType: TableOperationType) -> String {
            switch operationType {
            case .drop:
                return tableCount > 1
                    ? "Drop \(tableCount) tables"
                    : "Drop table '\(tableName)'"
            case .truncate:
                return tableCount > 1
                    ? "Truncate \(tableCount) tables"
                    : "Truncate table '\(tableName)'"
            }
        }

        static func isMultipleTables(tableCount: Int) -> Bool {
            tableCount > 1
        }

        static func cascadeSupported(databaseType: DatabaseType) -> Bool {
            databaseType == .postgresql
        }

        static func cascadeDisabled(operationType: TableOperationType, databaseType: DatabaseType) -> Bool {
            if operationType == .truncate && (databaseType == .mysql || databaseType == .mariadb) {
                return true
            }
            return !cascadeSupported(databaseType: databaseType)
        }

        static func ignoreFKDisabled(databaseType: DatabaseType) -> Bool {
            databaseType == .postgresql
        }

        static func ignoreFKDescription(databaseType: DatabaseType) -> String? {
            if databaseType == .postgresql {
                return "Not supported for PostgreSQL. Use CASCADE instead."
            }
            return nil
        }

        static func cascadeDescription(operationType: TableOperationType, databaseType: DatabaseType) -> String {
            switch operationType {
            case .drop:
                return "Drop all tables that depend on this table"
            case .truncate:
                if databaseType == .mysql || databaseType == .mariadb {
                    return "Not supported for TRUNCATE in MySQL/MariaDB"
                }
                return "Truncate all tables linked by foreign keys"
            }
        }
    }

    // MARK: - Title Logic

    @Test("Drop single table title")
    func testDropSingleTableTitle() {
        let result = DialogLogic.title(tableName: "users", tableCount: 1, operationType: .drop)
        #expect(result == "Drop table 'users'")
    }

    @Test("Drop multiple tables title")
    func testDropMultipleTablesTitle() {
        let result = DialogLogic.title(tableName: "users", tableCount: 3, operationType: .drop)
        #expect(result == "Drop 3 tables")
    }

    @Test("Truncate single table title")
    func testTruncateSingleTableTitle() {
        let result = DialogLogic.title(tableName: "orders", tableCount: 1, operationType: .truncate)
        #expect(result == "Truncate table 'orders'")
    }

    @Test("Truncate multiple tables title")
    func testTruncateMultipleTablesTitle() {
        let result = DialogLogic.title(tableName: "orders", tableCount: 5, operationType: .truncate)
        #expect(result == "Truncate 5 tables")
    }

    // MARK: - isMultipleTables

    @Test("tableCount 1 is not multiple")
    func testSingleTableNotMultiple() {
        #expect(DialogLogic.isMultipleTables(tableCount: 1) == false)
    }

    @Test("tableCount 2 is multiple")
    func testTwoTablesIsMultiple() {
        #expect(DialogLogic.isMultipleTables(tableCount: 2) == true)
    }

    @Test("tableCount 0 is not multiple")
    func testZeroTablesNotMultiple() {
        #expect(DialogLogic.isMultipleTables(tableCount: 0) == false)
    }

    // MARK: - cascadeSupported

    @Test("PostgreSQL supports cascade")
    func testPostgreSQLCascadeSupported() {
        #expect(DialogLogic.cascadeSupported(databaseType: .postgresql) == true)
    }

    @Test("MySQL does not support cascade")
    func testMySQLCascadeNotSupported() {
        #expect(DialogLogic.cascadeSupported(databaseType: .mysql) == false)
    }

    @Test("MariaDB does not support cascade")
    func testMariaDBCascadeNotSupported() {
        #expect(DialogLogic.cascadeSupported(databaseType: .mariadb) == false)
    }

    @Test("SQLite does not support cascade")
    func testSQLiteCascadeNotSupported() {
        #expect(DialogLogic.cascadeSupported(databaseType: .sqlite) == false)
    }

    @Test("MongoDB does not support cascade")
    func testMongoDBCascadeNotSupported() {
        #expect(DialogLogic.cascadeSupported(databaseType: .mongodb) == false)
    }

    // MARK: - cascadeDisabled

    @Test("PostgreSQL drop cascade is enabled")
    func testPostgreSQLDropCascadeEnabled() {
        #expect(DialogLogic.cascadeDisabled(operationType: .drop, databaseType: .postgresql) == false)
    }

    @Test("PostgreSQL truncate cascade is enabled")
    func testPostgreSQLTruncateCascadeEnabled() {
        #expect(DialogLogic.cascadeDisabled(operationType: .truncate, databaseType: .postgresql) == false)
    }

    @Test("MySQL drop cascade is disabled")
    func testMySQLDropCascadeDisabled() {
        #expect(DialogLogic.cascadeDisabled(operationType: .drop, databaseType: .mysql) == true)
    }

    @Test("MySQL truncate cascade is disabled")
    func testMySQLTruncateCascadeDisabled() {
        #expect(DialogLogic.cascadeDisabled(operationType: .truncate, databaseType: .mysql) == true)
    }

    @Test("MariaDB drop cascade is disabled")
    func testMariaDBDropCascadeDisabled() {
        #expect(DialogLogic.cascadeDisabled(operationType: .drop, databaseType: .mariadb) == true)
    }

    @Test("MariaDB truncate cascade is disabled")
    func testMariaDBTruncateCascadeDisabled() {
        #expect(DialogLogic.cascadeDisabled(operationType: .truncate, databaseType: .mariadb) == true)
    }

    @Test("SQLite drop cascade is disabled")
    func testSQLiteDropCascadeDisabled() {
        #expect(DialogLogic.cascadeDisabled(operationType: .drop, databaseType: .sqlite) == true)
    }

    @Test("SQLite truncate cascade is disabled")
    func testSQLiteTruncateCascadeDisabled() {
        #expect(DialogLogic.cascadeDisabled(operationType: .truncate, databaseType: .sqlite) == true)
    }

    // MARK: - ignoreFKDisabled

    @Test("PostgreSQL ignore FK is disabled")
    func testPostgreSQLIgnoreFKDisabled() {
        #expect(DialogLogic.ignoreFKDisabled(databaseType: .postgresql) == true)
    }

    @Test("MySQL ignore FK is enabled")
    func testMySQLIgnoreFKEnabled() {
        #expect(DialogLogic.ignoreFKDisabled(databaseType: .mysql) == false)
    }

    @Test("MariaDB ignore FK is enabled")
    func testMariaDBIgnoreFKEnabled() {
        #expect(DialogLogic.ignoreFKDisabled(databaseType: .mariadb) == false)
    }

    @Test("SQLite ignore FK is enabled")
    func testSQLiteIgnoreFKEnabled() {
        #expect(DialogLogic.ignoreFKDisabled(databaseType: .sqlite) == false)
    }

    // MARK: - ignoreFKDescription

    @Test("PostgreSQL ignore FK description mentions CASCADE")
    func testPostgreSQLIgnoreFKDescription() {
        let description = DialogLogic.ignoreFKDescription(databaseType: .postgresql)
        #expect(description != nil)
        #expect(description!.contains("CASCADE"))
    }

    @Test("MySQL ignore FK description is nil")
    func testMySQLIgnoreFKDescription() {
        #expect(DialogLogic.ignoreFKDescription(databaseType: .mysql) == nil)
    }

    @Test("SQLite ignore FK description is nil")
    func testSQLiteIgnoreFKDescription() {
        #expect(DialogLogic.ignoreFKDescription(databaseType: .sqlite) == nil)
    }

    // MARK: - cascadeDescription

    @Test("Drop cascade description mentions depend on this table")
    func testDropCascadeDescription() {
        let result = DialogLogic.cascadeDescription(operationType: .drop, databaseType: .postgresql)
        #expect(result.contains("depend on this table"))
    }

    @Test("Truncate PostgreSQL cascade description mentions foreign keys")
    func testTruncatePostgreSQLCascadeDescription() {
        let result = DialogLogic.cascadeDescription(operationType: .truncate, databaseType: .postgresql)
        #expect(result.contains("foreign keys"))
    }

    @Test("Truncate MySQL cascade description mentions Not supported")
    func testTruncateMySQLCascadeDescription() {
        let result = DialogLogic.cascadeDescription(operationType: .truncate, databaseType: .mysql)
        #expect(result.contains("Not supported"))
    }

    @Test("Truncate MariaDB cascade description mentions Not supported")
    func testTruncateMariaDBCascadeDescription() {
        let result = DialogLogic.cascadeDescription(operationType: .truncate, databaseType: .mariadb)
        #expect(result.contains("Not supported"))
    }

    // MARK: - TableOperationOptions

    @Test("Default options have ignoreForeignKeys false and cascade false")
    func testDefaultOptions() {
        let options = TableOperationOptions()
        #expect(options.ignoreForeignKeys == false)
        #expect(options.cascade == false)
    }

    @Test("TableOperationOptions Equatable")
    func testOptionsEquatable() {
        let a = TableOperationOptions(ignoreForeignKeys: true, cascade: false)
        let b = TableOperationOptions(ignoreForeignKeys: true, cascade: false)
        let c = TableOperationOptions(ignoreForeignKeys: false, cascade: true)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("TableOperationOptions Codable roundtrip")
    func testOptionsCodableRoundtrip() throws {
        let original = TableOperationOptions(ignoreForeignKeys: true, cascade: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TableOperationOptions.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - TableOperationType

    @Test("TableOperationType raw values")
    func testOperationTypeRawValues() {
        #expect(TableOperationType.truncate.rawValue == "truncate")
        #expect(TableOperationType.drop.rawValue == "drop")
    }

    @Test("TableOperationType Codable roundtrip")
    func testOperationTypeCodableRoundtrip() throws {
        for operationType in [TableOperationType.truncate, TableOperationType.drop] {
            let data = try JSONEncoder().encode(operationType)
            let decoded = try JSONDecoder().decode(TableOperationType.self, from: data)
            #expect(decoded == operationType)
        }
    }
}
