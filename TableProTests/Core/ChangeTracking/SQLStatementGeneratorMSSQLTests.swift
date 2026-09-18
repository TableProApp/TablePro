//
//  SQLStatementGeneratorMSSQLTests.swift
//  TableProTests
//
//  Tests for SQLStatementGenerator with databaseType: .mssql
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SQL Statement Generator MSSQL")
struct SQLStatementGeneratorMSSQLTests {
    // MARK: - Helpers

    private func makeGenerator(
        tableName: String = "users",
        columns: [String] = ["id", "name", "email"],
        primaryKeyColumns: [String] = ["id"]
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: .mssql,
            dialect: nil
        )
    }

    private func makeInsertChange(rowID: RowID = .existing(0)) -> RowChange {
        RowChange(rowID: rowID, type: .insert, cellChanges: [], originalRow: nil)
    }

    private func makeUpdateChange(
        rowID: RowID = .existing(0),
        columnName: String = "name",
        oldValue: String? = "old",
        newValue: String? = "new",
        originalRow: [String?]? = ["1", "old", "a@b.com"]
    ) -> RowChange {
        RowChange(
            rowID: rowID,
            type: .update,
            cellChanges: [
                CellChange(
                    columnIndex: 1,
                    columnName: columnName,
                    oldValue: PluginCellValue.fromOptional(oldValue),
                    newValue: PluginCellValue.fromOptional(newValue)
                )
            ],
            originalRow: originalRow.map { row in row.map(PluginCellValue.fromOptional) }
        )
    }

    private func makeDeleteChange(
        rowID: RowID = .existing(0),
        originalRow: [String?]? = ["1", "John", "john@example.com"]
    ) -> RowChange {
        RowChange(
            rowID: rowID, type: .delete, cellChanges: [],
            originalRow: originalRow.map { row in row.map(PluginCellValue.fromOptional) }
        )
    }

    // MARK: - Placeholder Tests

    @Test("INSERT statement uses question mark placeholders")
    func insertUsesQuestionMarkPlaceholders() throws {
        let generator = try makeGenerator()
        let insertedRowData: [RowID: [PluginCellValue]] = [.existing(0): ["1", "John", "john@example.com"]]
        let statements = generator.generateStatements(
            from: [makeInsertChange()],
            insertedRowData: insertedRowData,
            deletedRowIDs: [],
            insertedRowIDs: [.existing(0)]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("?"))
        #expect(!statements[0].sql.contains("$1"))
    }

    @Test("UPDATE statement uses question mark placeholders")
    func updateUsesQuestionMarkPlaceholders() throws {
        let generator = try makeGenerator()
        let statements = generator.generateStatements(
            from: [makeUpdateChange()],
            insertedRowData: [:],
            deletedRowIDs: [],
            insertedRowIDs: []
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("?"))
        #expect(!statements[0].sql.contains("$1"))
    }

    // MARK: - INSERT Tests

    @Test("INSERT uses bracket-quoted table and column names")
    func insertBracketQuoting() throws {
        let generator = try makeGenerator()
        let insertedRowData: [RowID: [PluginCellValue]] = [.existing(0): ["1", "John", "john@example.com"]]
        let statements = generator.generateStatements(
            from: [makeInsertChange()],
            insertedRowData: insertedRowData,
            deletedRowIDs: [],
            insertedRowIDs: [.existing(0)]
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("INSERT INTO [users]"))
        #expect(sql.contains("[id]"))
        #expect(sql.contains("[name]"))
        #expect(sql.contains("[email]"))
    }

    @Test("INSERT with multiple columns produces correct number of placeholders")
    func insertMultipleColumnsPlaceholders() throws {
        let generator = try makeGenerator(columns: ["id", "name", "email"])
        let insertedRowData: [RowID: [PluginCellValue]] = [.existing(0): ["1", "John", "john@example.com"]]
        let statements = generator.generateStatements(
            from: [makeInsertChange()],
            insertedRowData: insertedRowData,
            deletedRowIDs: [],
            insertedRowIDs: [.existing(0)]
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        let placeholderCount = sql.components(separatedBy: "?").count - 1
        #expect(placeholderCount == 3)
        #expect(statements[0].parameters.count == 3)
    }

    // MARK: - UPDATE Tests

    @Test("UPDATE uses bracket-quoted table and column names")
    func updateBracketQuoting() throws {
        let generator = try makeGenerator()
        let statements = generator.generateStatements(
            from: [makeUpdateChange()],
            insertedRowData: [:],
            deletedRowIDs: [],
            insertedRowIDs: []
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("UPDATE [users] SET [name] = ?"))
    }

    @Test("UPDATE WHERE clause uses primary key")
    func updateWhereClauseUsesPrimaryKey() throws {
        let generator = try makeGenerator()
        let statements = generator.generateStatements(
            from: [makeUpdateChange()],
            insertedRowData: [:],
            deletedRowIDs: [],
            insertedRowIDs: []
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("WHERE [id] = ?"))
    }

    // MARK: - DELETE Tests

    @Test("DELETE uses bracket-quoted table name")
    func deleteBracketQuoting() throws {
        let generator = try makeGenerator()
        let statements = generator.generateStatements(
            from: [makeDeleteChange()],
            insertedRowData: [:],
            deletedRowIDs: [.existing(0)],
            insertedRowIDs: []
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("DELETE FROM [users]"))
        #expect(sql.contains("WHERE [id] = ?"))
    }
}
