//
//  SQLStatementGeneratorMSSQLTests.swift
//  TableProTests
//
//  Tests for SQLStatementGenerator with databaseType: .mssql
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQL Statement Generator MSSQL")
struct SQLStatementGeneratorMSSQLTests {
    // MARK: - Helpers

    private func makeGenerator(
        tableName: String = "users",
        columns: [String] = ["id", "name", "email"],
        primaryKeyColumn: String? = "id"
    ) -> SQLStatementGenerator {
        SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: .mssql,
            dialect: nil
        )
    }

    private func makeInsertChange(rowIndex: Int = 0) -> RowChange {
        RowChange(rowIndex: rowIndex, type: .insert, cellChanges: [], originalRow: nil)
    }

    private func makeUpdateChange(
        rowIndex: Int = 0,
        columnName: String = "name",
        oldValue: String? = "old",
        newValue: String? = "new",
        originalRow: [String?]? = ["1", "old", "a@b.com"]
    ) -> RowChange {
        RowChange(
            rowIndex: rowIndex,
            type: .update,
            cellChanges: [
                CellChange(
                    rowIndex: rowIndex,
                    columnIndex: 1,
                    columnName: columnName,
                    oldValue: oldValue,
                    newValue: newValue
                )
            ],
            originalRow: originalRow
        )
    }

    private func makeDeleteChange(
        rowIndex: Int = 0,
        originalRow: [String?]? = ["1", "John", "john@example.com"]
    ) -> RowChange {
        RowChange(rowIndex: rowIndex, type: .delete, cellChanges: [], originalRow: originalRow)
    }

    // MARK: - Placeholder Tests

    @Test("INSERT statement uses question mark placeholders")
    func insertUsesQuestionMarkPlaceholders() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let statements = generator.generateStatements(
            from: [makeInsertChange()],
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("?"))
        #expect(!statements[0].sql.contains("$1"))
    }

    @Test("UPDATE statement uses question mark placeholders")
    func updateUsesQuestionMarkPlaceholders() {
        let generator = makeGenerator()
        let statements = generator.generateStatements(
            from: [makeUpdateChange()],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("?"))
        #expect(!statements[0].sql.contains("$1"))
    }

    // MARK: - INSERT Tests

    @Test("INSERT uses bracket-quoted table and column names")
    func insertBracketQuoting() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let statements = generator.generateStatements(
            from: [makeInsertChange()],
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("INSERT INTO [users]"))
        #expect(sql.contains("[id]"))
        #expect(sql.contains("[name]"))
        #expect(sql.contains("[email]"))
    }

    @Test("INSERT with multiple columns produces correct number of placeholders")
    func insertMultipleColumnsPlaceholders() {
        let generator = makeGenerator(columns: ["id", "name", "email"])
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let statements = generator.generateStatements(
            from: [makeInsertChange()],
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        let placeholderCount = sql.components(separatedBy: "?").count - 1
        #expect(placeholderCount == 3)
        #expect(statements[0].parameters.count == 3)
    }

    // MARK: - UPDATE Tests

    @Test("UPDATE uses bracket-quoted table and column names")
    func updateBracketQuoting() {
        let generator = makeGenerator()
        let statements = generator.generateStatements(
            from: [makeUpdateChange()],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("UPDATE [users] SET [name] = ?"))
    }

    @Test("UPDATE WHERE clause uses primary key")
    func updateWhereClauseUsesPrimaryKey() {
        let generator = makeGenerator()
        let statements = generator.generateStatements(
            from: [makeUpdateChange()],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("WHERE [id] = ?"))
    }

    // MARK: - DELETE Tests

    @Test("DELETE uses bracket-quoted table name")
    func deleteBracketQuoting() {
        let generator = makeGenerator()
        let statements = generator.generateStatements(
            from: [makeDeleteChange()],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("DELETE FROM [users]"))
        #expect(sql.contains("WHERE [id] = ?"))
    }

    @Test("DELETE does not add LIMIT clause for MSSQL")
    func deleteNoLimitClause() {
        let generator = makeGenerator()
        let statements = generator.generateStatements(
            from: [makeDeleteChange()],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        #expect(!statements[0].sql.contains("LIMIT"))
    }
}
