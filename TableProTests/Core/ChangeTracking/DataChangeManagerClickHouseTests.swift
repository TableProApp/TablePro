//
//  DataChangeManagerClickHouseTests.swift
//  TableProTests
//
//  Tests for ClickHouse-specific UPDATE statement validation in DataChangeManager.
//  ClickHouse uses ALTER TABLE ... UPDATE syntax instead of standard UPDATE.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
@Suite("DataChangeManager ClickHouse UPDATE Validation")
struct DataChangeManagerClickHouseTests {
    @Test("ClickHouse ALTER TABLE UPDATE passes validation without throwing")
    func alterTableUpdatePassesValidation() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "events",
            columns: ["id", "status"],
            primaryKeyColumns: ["id"],
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
            primaryKeyColumns: ["id"],
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

}
