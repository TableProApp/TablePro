//
//  DataChangeManagerClickHouseTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
struct DataChangeManagerClickHouseTests {
    @Test("A ClickHouse edit is refused and stays pending instead of keyed on the sorting key")
    func clickHouseEditIsRefusedAndStaysPending() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "events",
            columns: ["id", "status"],
            primaryKeyColumns: ["id"],
            databaseType: .clickhouse,
            generatedColumns: []
        )

        manager.recordCellChange(
            rowID: .existing(0),
            columnIndex: 1,
            columnName: "status",
            oldValue: "pending",
            newValue: "completed",
            originalRow: ["42", "pending"]
        )

        #expect(throws: DataWriteError.self) {
            _ = try manager.generateSQL()
        }
        #expect(manager.hasChanges)
    }

    @Test("Standard UPDATE prefix is still detected for non-ClickHouse databases")
    func standardUpdatePrefixDetected() async throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )

        manager.recordCellChange(
            rowID: .existing(0),
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
