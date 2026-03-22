//
//  SQLStatementGeneratorParameterStyleTests.swift
//  TableProTests
//
//  Tests for ParameterStyle integration in SQLStatementGenerator
//

import Foundation
import Testing

@testable import TablePro
@testable import TableProPluginKit

@Suite("SQL Statement Generator - Parameter Style")
struct SQLStatementGeneratorParameterStyleTests {
    // MARK: - Helper Methods

    private func makeGenerator(
        tableName: String = "users",
        columns: [String] = ["id", "name", "email"],
        primaryKeyColumn: String? = "id",
        databaseType: DatabaseType = .mysql,
        parameterStyle: ParameterStyle? = nil
    ) -> SQLStatementGenerator {
        SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
            parameterStyle: parameterStyle,
            dialect: nil
        )
    }

    // MARK: - Default Parameter Style Tests

    @Test("PostgreSQL defaults to dollar style")
    func testPostgreSQLDefaultsDollar() {
        let generator = makeGenerator(databaseType: .postgresql)
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: [], insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("$1"))
        #expect(statements[0].sql.contains("$2"))
        #expect(statements[0].sql.contains("$3"))
        #expect(!statements[0].sql.contains("?"))
    }

    @Test("Redshift defaults to dollar style")
    func testRedshiftDefaultsDollar() {
        let generator = makeGenerator(databaseType: .redshift)
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: [], insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("$1"))
    }

    @Test("DuckDB defaults to dollar style")
    func testDuckDBDefaultsDollar() {
        let generator = makeGenerator(databaseType: .duckdb)
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: [], insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("$1"))
    }

    @Test("MySQL defaults to questionMark style")
    func testMySQLDefaultsQuestionMark() {
        let generator = makeGenerator(databaseType: .mysql)
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: [], insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("?"))
        #expect(!statements[0].sql.contains("$1"))
    }

    @Test("SQLite defaults to questionMark style")
    func testSQLiteDefaultsQuestionMark() {
        let generator = makeGenerator(databaseType: .sqlite)
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: [], insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("?"))
        #expect(!statements[0].sql.contains("$1"))
    }

    @Test("MSSQL defaults to questionMark style")
    func testMSSQLDefaultsQuestionMark() {
        let generator = makeGenerator(databaseType: .mssql)
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: [], insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("?"))
        #expect(!statements[0].sql.contains("$1"))
    }

    // MARK: - Explicit Parameter Style Override

    @Test("Dollar style generates $1, $2 placeholders for INSERT")
    func testDollarStyleInsert() {
        let generator = makeGenerator(parameterStyle: .dollar)
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: [], insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("$1"))
        #expect(sql.contains("$2"))
        #expect(sql.contains("$3"))
    }

    @Test("QuestionMark style generates ? placeholders for INSERT")
    func testQuestionMarkStyleInsert() {
        let generator = makeGenerator(parameterStyle: .questionMark)
        let insertedRowData: [Int: [String?]] = [0: ["1", "John", "john@example.com"]]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: [], insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("?"))
        #expect(!sql.contains("$1"))
    }

    @Test("Dollar style generates $N placeholders for UPDATE with PK")
    func testDollarStyleUpdate() {
        let generator = makeGenerator(databaseType: .postgresql, parameterStyle: .dollar)
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Jane")
                ],
                originalRow: ["1", "John", "john@example.com"]
            )
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: [:],
            deletedRowIndices: [], insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("$1"))
        #expect(sql.contains("$2"))
    }

    @Test("Dollar style generates $N placeholders for DELETE with PK")
    func testDollarStyleDelete() {
        let generator = makeGenerator(databaseType: .postgresql, parameterStyle: .dollar)
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .delete,
                cellChanges: [],
                originalRow: ["1", "John", "john@example.com"]
            )
        ]

        let statements = generator.generateStatements(
            from: changes, insertedRowData: [:],
            deletedRowIndices: [0], insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("$1"))
        #expect(!sql.contains("?"))
    }
}
