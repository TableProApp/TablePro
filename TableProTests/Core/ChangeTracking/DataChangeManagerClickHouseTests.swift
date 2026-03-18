//
//  DataChangeManagerClickHouseTests.swift
//  TableProTests
//
//  Tests for ClickHouse-specific UPDATE statement validation in DataChangeManager.
//  ClickHouse uses ALTER TABLE ... UPDATE syntax instead of standard UPDATE.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("DataChangeManager ClickHouse UPDATE Validation")
struct DataChangeManagerClickHouseTests {
    @Test("ClickHouse ALTER TABLE UPDATE is counted as an update statement")
    func alterTableUpdateCounted() async throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumn: "id",
            databaseType: .clickhouse
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob",
            originalRow: ["1", "Alice"]
        )

        #expect(manager.hasChanges)

        let statements = try manager.generateSQL()
        #expect(!statements.isEmpty)

        // ClickHouse generates ALTER TABLE ... UPDATE instead of UPDATE
        let hasAlterTableUpdate = statements.contains { $0.sql.hasPrefix("ALTER TABLE") }
        #expect(hasAlterTableUpdate)
    }

    @Test("ClickHouse ALTER TABLE UPDATE passes validation without throwing")
    func alterTableUpdatePassesValidation() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "events",
            columns: ["id", "status"],
            primaryKeyColumn: "id",
            databaseType: .clickhouse
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "status",
            oldValue: "pending",
            newValue: "completed",
            originalRow: ["42", "pending"]
        )

        // Should not throw — ALTER TABLE UPDATE must be recognized as valid
        #expect(throws: Never.self) {
            _ = try manager.generateSQL()
        }
    }

    @Test("Standard UPDATE prefix is still detected for non-ClickHouse databases")
    func standardUpdatePrefixDetected() async throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumn: "id",
            databaseType: .mysql
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob",
            originalRow: ["1", "Alice"]
        )

        let statements = try manager.generateSQL()
        #expect(!statements.isEmpty)

        let hasStandardUpdate = statements.contains { $0.sql.hasPrefix("UPDATE") }
        #expect(hasStandardUpdate)
    }

    @Test("ClickHouse UPDATE without primary key uses all columns in WHERE clause")
    func clickhouseUpdateWithoutPrimaryKey() async throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "logs",
            columns: ["timestamp", "message"],
            primaryKeyColumn: nil,
            databaseType: .clickhouse
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "message",
            oldValue: "old log",
            newValue: "new log",
            originalRow: ["2024-01-01", "old log"]
        )

        let statements = try manager.generateSQL()
        #expect(!statements.isEmpty)

        let alterStatement = statements.first { $0.sql.hasPrefix("ALTER TABLE") }
        #expect(alterStatement != nil)
        #expect(alterStatement?.sql.contains("UPDATE") == true)
        #expect(alterStatement?.sql.contains("WHERE") == true)
    }
}
