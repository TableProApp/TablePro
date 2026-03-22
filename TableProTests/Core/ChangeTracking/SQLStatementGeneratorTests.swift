//
//  SQLStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for SQLStatementGenerator
//

import Foundation
import Testing
@testable import TablePro

@Suite("SQL Statement Generator")
struct SQLStatementGeneratorTests {

    // MARK: - Helper Methods

    private func makeGenerator(
        tableName: String = "users",
        columns: [String] = ["id", "name", "email"],
        primaryKeyColumn: String? = "id",
        databaseType: DatabaseType = .mysql
    ) -> SQLStatementGenerator {
        return SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
            dialect: nil
        )
    }

    // MARK: - INSERT Tests

    @Test("Simple insert from insertedRowData (MySQL)")
    func testSimpleInsertMySQL() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .insert,
                cellChanges: [],
                originalRow: nil
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("INSERT INTO"))
        #expect(stmt.sql.contains("`users`"))
        #expect(stmt.sql.contains("`id`"))
        #expect(stmt.sql.contains("`name`"))
        #expect(stmt.sql.contains("`email`"))
        #expect(stmt.sql.contains("?"))
        #expect(stmt.parameters.count == 3)
        #expect(stmt.parameters[0] as? String == "1")
        #expect(stmt.parameters[1] as? String == "John")
        #expect(stmt.parameters[2] as? String == "john@example.com")
    }

    @Test("Insert with NULL value")
    func testInsertWithNullValue() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", nil]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].parameters.count == 3)
        #expect(statements[0].parameters[2] == nil)
    }

    @Test("Insert skips __DEFAULT__ columns")
    func testInsertSkipsDefaultColumns() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [
            0: ["__DEFAULT__", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(!stmt.sql.contains("`id`"))
        #expect(stmt.sql.contains("`name`"))
        #expect(stmt.sql.contains("`email`"))
        #expect(stmt.parameters.count == 2)
    }

    @Test("Insert with all __DEFAULT__ returns empty")
    func testInsertAllDefaultReturnsEmpty() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [
            0: ["__DEFAULT__", "__DEFAULT__", "__DEFAULT__"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.isEmpty)
    }

    @Test("Insert from cellChanges fallback")
    func testInsertFromCellChangesFallback() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .insert,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 0, columnName: "id", oldValue: nil, newValue: "1"),
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: nil, newValue: "John"),
                    CellChange(rowIndex: 0, columnIndex: 2, columnName: "email", oldValue: nil, newValue: "john@example.com")
                ],
                originalRow: nil
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].parameters.count == 3)
    }

    @Test("Insert with SQL function is inlined")
    func testInsertWithSQLFunction() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "NOW()"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("NOW()"))
        #expect(stmt.parameters.count == 2)
    }

    @Test("PostgreSQL insert uses $1, $2 placeholders")
    func testInsertPostgreSQLPlaceholders() {
        let generator = makeGenerator(databaseType: .postgresql)
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("$1"))
        #expect(statements[0].sql.contains("$2"))
        #expect(statements[0].sql.contains("$3"))
    }

    @Test("Table name is quoted with identifier quote")
    func testTableNameQuoted() {
        let generator = makeGenerator(tableName: "my_table")
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("`my_table`"))
    }

    @Test("Column names are quoted")
    func testColumnNamesQuoted() {
        let generator = makeGenerator(columns: ["user_id", "full_name", "email_address"])
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("`user_id`"))
        #expect(stmt.sql.contains("`full_name`"))
        #expect(stmt.sql.contains("`email_address`"))
    }

    @Test("Insert multiple rows generates separate statements")
    func testInsertMultipleRows() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"],
            1: ["2", "Jane", "jane@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil),
            RowChange(rowIndex: 1, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0, 1]
        )

        #expect(statements.count == 2)
        #expect(statements[0].parameters[1] as? String == "John")
        #expect(statements[1].parameters[1] as? String == "Jane")
    }

    // MARK: - UPDATE Tests

    @Test("Simple update (MySQL)")
    func testSimpleUpdateMySQL() {
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
        #expect(stmt.parameters.count == 2)
        #expect(stmt.parameters[0] as? String == "Johnny")
        #expect(stmt.parameters[1] as? String == "1")
    }

    @Test("Update with multiple columns")
    func testUpdateMultipleColumns() {
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
        #expect(stmt.sql.contains("`name` = ?"))
        #expect(stmt.sql.contains("`email` = ?"))
        #expect(stmt.parameters.count == 3)
    }

    @Test("Update with NULL new value")
    func testUpdateWithNullNewValue() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 2, columnName: "email", oldValue: "john@example.com", newValue: nil)
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
        #expect(statements[0].parameters[0] == nil)
    }

    @Test("Update with __DEFAULT__ value")
    func testUpdateWithDefaultValue() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "__DEFAULT__")
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
        #expect(stmt.sql.contains("`name` = DEFAULT"))
        #expect(stmt.parameters.count == 1)
    }

    @Test("Update with SQL function value is inlined")
    func testUpdateWithSQLFunction() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 2, columnName: "email", oldValue: "old@example.com", newValue: "CURRENT_TIMESTAMP()")
                ],
                originalRow: ["1", "John", "old@example.com"]
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
        #expect(stmt.sql.contains("CURRENT_TIMESTAMP()"))
        #expect(stmt.parameters.count == 1)
    }

    @Test("MySQL/MariaDB update adds LIMIT 1")
    func testUpdateMySQLLimitOne() {
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
        #expect(statements[0].sql.contains("LIMIT 1"))
    }

    @Test("PostgreSQL update does NOT add LIMIT 1")
    func testUpdatePostgreSQLNoLimit() {
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
        #expect(!statements[0].sql.contains("LIMIT"))
    }

    @Test("PostgreSQL update uses $1, $2 placeholders in order")
    func testUpdatePostgreSQLPlaceholders() {
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
        #expect(stmt.sql.contains("$1"))
        #expect(stmt.sql.contains("$2"))
    }

    @Test("Update PK value from originalRow")
    func testUpdatePKFromOriginalRow() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Johnny")
                ],
                originalRow: ["42", "John", "john@example.com"]
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        #expect(statements[0].parameters.last as? String == "42")
    }

    // MARK: - DELETE Tests

    @Test("Batch delete with PK (MySQL)")
    func testBatchDeleteWithPK() {
        let generator = makeGenerator()
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
        #expect(stmt.sql.contains("DELETE FROM"))
        #expect(stmt.sql.contains("WHERE"))
        #expect(stmt.sql.contains("`id` = ?"))
    }

    @Test("Batch delete with PK, multiple rows")
    func testBatchDeleteMultipleRows() {
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

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("OR"))
        #expect(stmt.parameters.count == 2)
        #expect(stmt.parameters[0] as? String == "1")
        #expect(stmt.parameters[1] as? String == "2")
    }

    @Test("Individual delete without PK matches all columns")
    func testIndividualDeleteNoPK() {
        let generator = makeGenerator(primaryKeyColumn: nil)
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
        #expect(stmt.sql.contains("`id` = ?"))
        #expect(stmt.sql.contains("`name` = ?"))
        #expect(stmt.sql.contains("`email` = ?"))
        #expect(stmt.sql.contains("AND"))
        #expect(stmt.parameters.count == 3)
    }

    @Test("Individual delete with NULL column uses IS NULL")
    func testIndividualDeleteWithNull() {
        let generator = makeGenerator(primaryKeyColumn: nil)
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .delete,
                cellChanges: [],
                originalRow: ["1", "John", nil]
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
        #expect(stmt.sql.contains("IS NULL"))
        #expect(stmt.parameters.count == 2)
    }

    @Test("MySQL/MariaDB individual delete adds LIMIT 1")
    func testDeleteMySQLLimitOne() {
        let generator = makeGenerator(primaryKeyColumn: nil, databaseType: .mysql)
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
        #expect(statements[0].sql.contains("LIMIT 1"))
    }

    @Test("PostgreSQL delete no LIMIT 1")
    func testDeletePostgreSQLNoLimit() {
        let generator = makeGenerator(primaryKeyColumn: nil, databaseType: .postgresql)
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
        #expect(!statements[0].sql.contains("LIMIT"))
    }

    @Test("PostgreSQL delete uses $N placeholders")
    func testDeletePostgreSQLPlaceholders() {
        let generator = makeGenerator(databaseType: .postgresql)
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

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("$1"))
        #expect(stmt.sql.contains("$2"))
    }

    @Test("Delete requires originalRow - nil returns nil")
    func testDeleteRequiresOriginalRow() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.isEmpty)
    }

    @Test("Empty changes returns empty result")
    func testEmptyChanges() {
        let generator = makeGenerator()

        let statements = generator.generateStatements(
            from: [],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.isEmpty)
    }

    @Test("Mix of insert, update, delete all generated")
    func testMixedOperations() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil),
            RowChange(
                rowIndex: 1,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 1, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Johnny")
                ],
                originalRow: ["1", "John", "john@example.com"]
            ),
            RowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: ["2", "Jane", "jane@example.com"])
        ]
        let insertedRowData: [Int: [String?]] = [
            0: ["3", "Bob", "bob@example.com"]
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [2],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 3)
    }

    // MARK: - Placeholder Tests

    @Test("MySQL uses ? for all placeholders")
    func testMySQLPlaceholders() {
        let generator = makeGenerator(databaseType: .mysql)
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let questionMarkCount = statements[0].sql.filter { $0 == "?" }.count
        #expect(questionMarkCount == 3)
        #expect(!statements[0].sql.contains("$"))
    }

    @Test("PostgreSQL uses $1, $2, $3 sequentially")
    func testPostgreSQLSequentialPlaceholders() {
        let generator = makeGenerator(databaseType: .postgresql)
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("$1"))
        #expect(stmt.sql.contains("$2"))
        #expect(stmt.sql.contains("$3"))
        #expect(!stmt.sql.contains("?"))
    }

    @Test("SQLite uses ? placeholders")
    func testSQLitePlaceholders() {
        let generator = makeGenerator(databaseType: .sqlite)
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let questionMarkCount = statements[0].sql.filter { $0 == "?" }.count
        #expect(questionMarkCount == 3)
    }

    @Test("MariaDB uses ? placeholders")
    func testMariaDBPlaceholders() {
        let generator = makeGenerator(databaseType: .mariadb)
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let questionMarkCount = statements[0].sql.filter { $0 == "?" }.count
        #expect(questionMarkCount == 3)
    }

    // MARK: - Safety Tests

    @Test("Insert only processes rows in insertedRowIndices set")
    func testInsertOnlyProcessesInsertedRows() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"],
            1: ["2", "Jane", "jane@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil),
            RowChange(rowIndex: 1, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        #expect(statements[0].parameters[1] as? String == "John")
    }

    @Test("Delete only processes rows in deletedRowIndices set")
    func testDeleteOnlyProcessesDeletedRows() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["1", "John", "john@example.com"]),
            RowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: ["2", "Jane", "jane@example.com"])
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        #expect(statements[0].parameters.count == 1)
        #expect(statements[0].parameters[0] as? String == "1")
    }

    @Test("Row not in insertedRowIndices is skipped")
    func testRowNotInInsertedRowIndicesSkipped() {
        let generator = makeGenerator()
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.isEmpty)
    }

    @Test("Row not in deletedRowIndices is skipped")
    func testRowNotInDeletedRowIndicesSkipped() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["1", "John", "john@example.com"])
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.isEmpty)
    }

    // MARK: - Integration Tests

    @Test("Full workflow: insert + update + delete in one call")
    func testFullWorkflowIntegration() {
        let generator = makeGenerator()
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil),
            RowChange(
                rowIndex: 1,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 1, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Johnny")
                ],
                originalRow: ["1", "John", "john@example.com"]
            ),
            RowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: ["2", "Jane", "jane@example.com"])
        ]
        let insertedRowData: [Int: [String?]] = [
            0: ["3", "Bob", "bob@example.com"]
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [2],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 3)
        #expect(statements[0].sql.contains("INSERT"))
        #expect(statements[1].sql.contains("UPDATE"))
        #expect(statements[2].sql.contains("DELETE"))
    }

    @Test("Verify parameter order matches placeholder order")
    func testParameterOrderMatchesPlaceholders() {
        let generator = makeGenerator(databaseType: .postgresql)
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
        #expect(stmt.parameters.count == 3)
        #expect(stmt.parameters[0] as? String == "Johnny")
        #expect(stmt.parameters[1] as? String == "johnny@example.com")
        #expect(stmt.parameters[2] as? String == "1")

        // PostgreSQL uses double quotes for identifier quoting
        let nameIndex = stmt.sql.range(of: "\"name\" = $1")
        let emailIndex = stmt.sql.range(of: "\"email\" = $2")
        let whereIndex = stmt.sql.range(of: "\"id\" = $3")
        #expect(nameIndex != nil)
        #expect(emailIndex != nil)
        #expect(whereIndex != nil)
    }

    // MARK: - Redshift Tests

    @Test("Redshift insert uses $1, $2 placeholders")
    func testInsertRedshiftPlaceholders() {
        let generator = makeGenerator(databaseType: .redshift)
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("$1"))
        #expect(stmt.sql.contains("$2"))
        #expect(stmt.sql.contains("$3"))
        #expect(!stmt.sql.contains("?"))
    }

    @Test("Redshift insert uses double-quote identifier quoting")
    func testInsertRedshiftQuoting() {
        let generator = makeGenerator(databaseType: .redshift)
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("\"users\""))
        #expect(stmt.sql.contains("\"id\""))
        #expect(stmt.sql.contains("\"name\""))
        #expect(stmt.sql.contains("\"email\""))
        #expect(!stmt.sql.contains("`"))
    }

    @Test("Redshift update uses $1, $2 placeholders in order")
    func testUpdateRedshiftPlaceholders() {
        let generator = makeGenerator(databaseType: .redshift)
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
        #expect(stmt.sql.contains("$1"))
        #expect(stmt.sql.contains("$2"))
        #expect(!stmt.sql.contains("?"))
    }

    @Test("Redshift update does NOT add LIMIT 1")
    func testUpdateRedshiftNoLimit() {
        let generator = makeGenerator(databaseType: .redshift)
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
        #expect(!statements[0].sql.contains("LIMIT"))
    }

    @Test("Redshift delete uses $N placeholders")
    func testDeleteRedshiftPlaceholders() {
        let generator = makeGenerator(databaseType: .redshift)
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

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("$1"))
        #expect(stmt.sql.contains("$2"))
        #expect(!stmt.sql.contains("?"))
    }

    @Test("Redshift delete no LIMIT 1")
    func testDeleteRedshiftNoLimit() {
        let generator = makeGenerator(primaryKeyColumn: nil, databaseType: .redshift)
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
        #expect(!statements[0].sql.contains("LIMIT"))
    }

    @Test("Redshift uses $1, $2, $3 sequentially for insert")
    func testRedshiftSequentialPlaceholders() {
        let generator = makeGenerator(databaseType: .redshift)
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "John", "john@example.com"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("$1"))
        #expect(stmt.sql.contains("$2"))
        #expect(stmt.sql.contains("$3"))
        #expect(!stmt.sql.contains("?"))
    }

    @Test("Redshift parameter order matches placeholder order")
    func testRedshiftParameterOrder() {
        let generator = makeGenerator(databaseType: .redshift)
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
        #expect(stmt.parameters.count == 3)
        #expect(stmt.parameters[0] as? String == "Johnny")
        #expect(stmt.parameters[1] as? String == "johnny@example.com")
        #expect(stmt.parameters[2] as? String == "1")

        #expect(stmt.sql.range(of: "\"name\" = $1") != nil)
        #expect(stmt.sql.range(of: "\"email\" = $2") != nil)
        #expect(stmt.sql.range(of: "\"id\" = $3") != nil)
    }

    // MARK: - Reserved Keyword Column Name Regression (GH-373)

    @Test("UPDATE quotes reserved keyword column names in MySQL")
    func testUpdateQuotesReservedKeywordColumnMySQL() {
        let generator = makeGenerator(
            tableName: "connections",
            columns: ["id", "database", "table", "order"],
            primaryKeyColumn: "id"
        )
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "database", oldValue: "old_db", newValue: "new_db")
                ],
                originalRow: ["1", "old_db", "users", "5"]
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
        #expect(stmt.sql.contains("`database` = ?"))
        #expect(stmt.sql.contains("WHERE `id` = ?"))
        #expect(!stmt.sql.contains("SET database ="))
    }

    @Test("INSERT quotes reserved keyword column names in MySQL")
    func testInsertQuotesReservedKeywordColumnMySQL() {
        let generator = makeGenerator(
            tableName: "connections",
            columns: ["id", "database", "order"],
            primaryKeyColumn: "id"
        )
        let insertedRowData: [Int: [String?]] = [
            0: ["1", "mydb", "5"]
        ]
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("`database`"))
        #expect(stmt.sql.contains("`order`"))
        #expect(!stmt.sql.contains("(database,"))
        #expect(!stmt.sql.contains(", order)"))
    }

    @Test("DELETE quotes reserved keyword column names in MySQL (no PK)")
    func testDeleteQuotesReservedKeywordColumnMySQL() {
        let generator = makeGenerator(
            tableName: "connections",
            columns: ["id", "database", "select"],
            primaryKeyColumn: nil
        )
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .delete,
                cellChanges: [],
                originalRow: ["1", "mydb", "foo"]
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
        #expect(stmt.sql.contains("`database`"))
        #expect(stmt.sql.contains("`select`"))
    }

    @Test("UPDATE quotes reserved keyword column names in PostgreSQL")
    func testUpdateQuotesReservedKeywordColumnPostgreSQL() {
        let generator = makeGenerator(
            tableName: "connections",
            columns: ["id", "database", "order"],
            primaryKeyColumn: "id",
            databaseType: .postgresql
        )
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 1, columnName: "database", oldValue: "old_db", newValue: "new_db")
                ],
                originalRow: ["1", "old_db", "5"]
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
        // PostgreSQL uses double quotes
        #expect(stmt.sql.contains("\"database\" = $1"))
        #expect(stmt.sql.contains("\"id\" = $2"))
    }
}
