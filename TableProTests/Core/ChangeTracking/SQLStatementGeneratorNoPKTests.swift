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
        primaryKeyColumn: String? = nil,
        databaseType: DatabaseType = .mysql
    ) -> SQLStatementGenerator {
        SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
            dialect: nil
        )
    }

    // MARK: - UPDATE without PK

    @Test("Update without primary key uses all columns in WHERE")
    func testUpdateNoPrimaryKey() {
        let generator = makeGenerator()
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
        #expect(stmt.sql.contains("LIMIT 1"))
    }

    @Test("Update without PK — MySQL uses LIMIT 1")
    func testUpdateNoPKMySQLLimit() {
        let generator = makeGenerator(databaseType: .mysql)
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
        #expect(stmt.sql.contains("LIMIT 1"))
        #expect(stmt.sql.contains("SET `name` = ?"))
        #expect(stmt.sql.contains("WHERE `id` = ? AND `name` = ? AND `email` = ?"))
        #expect(stmt.parameters.count == 4) // 1 SET + 3 WHERE
        #expect(stmt.parameters[0] as? String == "Johnny")
        #expect(stmt.parameters[1] as? String == "1")
        #expect(stmt.parameters[2] as? String == "John")
        #expect(stmt.parameters[3] as? String == "john@example.com")
    }

    @Test("Update without PK — PostgreSQL uses $N placeholders, no LIMIT")
    func testUpdateNoPKPostgreSQLNoLimit() {
        let generator = makeGenerator(databaseType: .postgresql)
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
        #expect(!stmt.sql.contains("LIMIT"))
        #expect(!stmt.sql.contains("TOP"))
        #expect(stmt.sql.contains("\"name\" = $1"))
        #expect(stmt.sql.contains("\"id\" = $2"))
        #expect(stmt.sql.contains("\"name\" = $3"))
        #expect(stmt.sql.contains("\"email\" = $4"))
        #expect(stmt.parameters.count == 4)
    }

    @Test("Update without PK — SQLite uses LIMIT 1")
    func testUpdateNoPKSQLiteLimit() {
        let generator = makeGenerator(databaseType: .sqlite)
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
        #expect(stmt.sql.contains("LIMIT 1"))
        #expect(stmt.sql.contains("SET `name` = ?"))
    }

    @Test("Update without PK — MSSQL uses UPDATE TOP (1)")
    func testUpdateNoPKMSSQLTop() {
        let generator = makeGenerator(databaseType: .mssql)
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
        #expect(stmt.sql.hasPrefix("UPDATE TOP (1)"))
        #expect(!stmt.sql.contains("LIMIT"))
        #expect(stmt.sql.contains("[name] = ?"))
    }

    @Test("Update without PK — NULL in originalRow uses IS NULL")
    func testUpdateNoPKWithNull() {
        let generator = makeGenerator()
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
    func testUpdateNoPKMissingOriginalRow() {
        let generator = makeGenerator()
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
    func testUpdateNoPKMultipleColumnsChanged() {
        let generator = makeGenerator()
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

    @Test("Delete without PK — MSSQL uses DELETE TOP (1)")
    func testDeleteNoPKMSSQLTop() {
        let generator = makeGenerator(databaseType: .mssql)
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .delete,
                cellChanges: [],
                originalRow: ["1", "John", "john@example.com"]
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
        #expect(stmt.sql.hasPrefix("DELETE TOP (1) FROM"))
        #expect(!stmt.sql.contains("LIMIT"))
    }

    @Test("Delete without PK — SQLite uses LIMIT 1")
    func testDeleteNoPKSQLiteLimit() {
        let generator = makeGenerator(databaseType: .sqlite)
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .delete,
                cellChanges: [],
                originalRow: ["1", "John", "john@example.com"]
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
        #expect(stmt.sql.contains("LIMIT 1"))
        #expect(stmt.sql.contains("DELETE FROM"))
    }

    @Test("Delete without PK — multiple rows generate individual DELETEs")
    func testDeleteNoPKMultipleRows() {
        let generator = makeGenerator()
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
    func testDeleteNoPKAllNull() {
        let generator = makeGenerator()
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
    func testDeleteNoPKMissingOriginalRow() {
        let generator = makeGenerator()
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
    func testMixedUpdateDeleteNoPK() {
        let generator = makeGenerator()
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
    func testInsertDeleteNoPK() {
        let generator = makeGenerator()
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
