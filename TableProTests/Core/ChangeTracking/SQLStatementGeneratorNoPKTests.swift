//
//  SQLStatementGeneratorNoPKTests.swift
//  TableProTests
//
//  Tests for SQL statement generation on tables without a primary key
//

import Foundation
import Testing
@testable import TablePro

@Suite("SQL Statement Generator — No Primary Key")
struct SQLStatementGeneratorNoPKTests {
    // MARK: - Helper Methods

    private func makeGenerator(
        tableName: String = "users",
        columns: [String] = ["id", "name", "email"],
        primaryKeyColumns: [String] = [],
        databaseType: DatabaseType = .mysql
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            dialect: nil
        )
    }

    // MARK: - UPDATE without PK

    @Test("Update without primary key uses all columns in WHERE")
    func testUpdateNoPrimaryKey() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Johnny")
                ],
                originalRow: ["1", "John", "john@example.com"]
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("UPDATE"))
        #expect(stmt.sql.contains("SET"))
        #expect(stmt.sql.contains("`name` = ?"))
        #expect(stmt.sql.contains("WHERE"))
        #expect(stmt.sql.contains("`id` = ?"))
        #expect(stmt.sql.contains("`name` = ?"))
        #expect(stmt.sql.contains("`email` = ?"))
    }

    @Test("Update without PK — NULL in originalRow uses IS NULL")
    func testUpdateNoPKWithNull() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: nil, newValue: "Johnny")
                ],
                originalRow: ["1", nil, "john@example.com"]
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("`name` IS NULL"))
        #expect(stmt.parameters.count == 3) // 1 SET + 2 WHERE (id, email — name is IS NULL)
    }

    @Test("Update without PK — missing originalRow returns empty")
    func testUpdateNoPKMissingOriginalRow() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Johnny")
                ],
                originalRow: nil
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.isEmpty)
    }

    @Test("Update without PK — multiple columns changed")
    func testUpdateNoPKMultipleColumnsChanged() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Johnny"),
                    CellChange(rowIndex: 0, columnIndex: 2, columnName: "email", oldValue: "john@example.com", newValue: "johnny@example.com")
                ],
                originalRow: ["1", "John", "john@example.com"]
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("SET `name` = ?, `email` = ?"))
        #expect(stmt.sql.contains("WHERE `id` = ? AND `name` = ? AND `email` = ?"))
        #expect(stmt.parameters.count == 5) // 2 SET + 3 WHERE
    }

    // MARK: - DELETE without PK

    @Test("Delete without PK — multiple rows generate individual DELETEs")
    func testDeleteNoPKMultipleRows() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["1", "John", "john@example.com"]),
            RowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: ["2", "Jane", "jane@example.com"])
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0, 1],
            insertedRowIndices: []
        )

        #expect(statements.count == 2)
        #expect(statements[0].sql.contains("DELETE"))
        #expect(statements[1].sql.contains("DELETE"))
        #expect(statements[0].parameters[0] as? String == "1")
        #expect(statements[1].parameters[0] as? String == "2")
    }

    @Test("Delete without PK — all NULL originalRow uses IS NULL")
    func testDeleteNoPKAllNull() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .delete,
                cellChanges: [],
                originalRow: [nil, nil, nil]
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("`id` IS NULL"))
        #expect(stmt.sql.contains("`name` IS NULL"))
        #expect(stmt.sql.contains("`email` IS NULL"))
        #expect(stmt.parameters.isEmpty)
    }

    @Test("Delete without PK — missing originalRow returns empty")
    func testDeleteNoPKMissingOriginalRow() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .delete,
                cellChanges: [],
                originalRow: nil
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.isEmpty)
    }

    // MARK: - Mixed Operations without PK

    @Test("Mixed UPDATE + DELETE without PK generates both")
    func testMixedUpdateDeleteNoPK() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Johnny")
                ],
                originalRow: ["1", "John", "john@example.com"]
            ),
            RowChange(
                rowIndex: 1,
                type: .delete,
                cellChanges: [],
                originalRow: ["2", "Jane", "jane@example.com"]
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [1],
            insertedRowIndices: []
        )

        #expect(statements.count == 2)
        #expect(statements[0].sql.contains("UPDATE"))
        #expect(statements[1].sql.contains("DELETE"))
    }

    @Test("INSERT + DELETE without PK — INSERT unaffected")
    func testInsertDeleteNoPK() throws {
        let generator = try makeGenerator()
        let insertedRowData: [Int: [String?]] = [
            0: ["3", "Bob", "bob@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil),
            RowChange(
                rowIndex: 1,
                type: .delete,
                cellChanges: [],
                originalRow: ["2", "Jane", "jane@example.com"]
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [1],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 2)
        #expect(statements[0].sql.contains("INSERT"))
        #expect(statements[1].sql.contains("DELETE"))
    }
}
