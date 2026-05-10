//
//  SQLStatementGeneratorPKRegressionTests.swift
//  TableProTests
//
//  Regression tests verifying DELETE/UPDATE uses PK-only WHERE clause
//  for each database type that previously had broken PK detection.
//

import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SQL Statement Generator PK Regression")
struct SQLStatementGeneratorPKRegressionTests {
    private func makeGenerator(
        tableName: String = "users",
        columns: [String] = ["id", "name", "email"],
        primaryKeyColumns: [String] = ["id"],
        databaseType: DatabaseType = .postgresql
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            dialect: nil
        )
    }

    private func makeDeleteChange(rowIndex: Int, originalRow: [String?]) -> RowChange {
        RowChange(
            rowIndex: rowIndex,
            type: .delete,
            cellChanges: [],
            originalRow: originalRow.map(PluginCellValue.fromOptional)
        )
    }

    private func makeUpdateChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?,
        originalRow: [String?]
    ) -> RowChange {
        RowChange(
            rowIndex: rowIndex,
            type: .update,
            cellChanges: [CellChange(rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName, oldValue: PluginCellValue.fromOptional(oldValue), newValue: PluginCellValue.fromOptional(newValue))],
            originalRow: originalRow.map(PluginCellValue.fromOptional)
        )
    }

    // MARK: - PostgreSQL DELETE with PK

    @Test("PostgreSQL delete with PK uses $N placeholder and PK-only WHERE")
    func testPostgreSQLDeleteWithPK() throws {
        let generator = try makeGenerator(databaseType: .postgresql)
        let changes = [makeDeleteChange(rowIndex: 0, originalRow: ["1", "John", "john@test.com"])]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("DELETE FROM"))
        #expect(stmt.sql.contains("\"users\""))
        #expect(stmt.sql.contains("\"id\" = $1"))
        #expect(!stmt.sql.contains("\"name\""))
        #expect(!stmt.sql.contains("\"email\""))
        #expect(stmt.parameters.count == 1)
        #expect(stmt.parameters[0] as? String == "1")
    }

    @Test("PostgreSQL batch delete with PK uses OR")
    func testPostgreSQLBatchDeleteWithPK() throws {
        let generator = try makeGenerator(databaseType: .postgresql)
        let changes = [
            makeDeleteChange(rowIndex: 0, originalRow: ["1", "John", "john@test.com"]),
            makeDeleteChange(rowIndex: 1, originalRow: ["2", "Jane", "jane@test.com"])
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0, 1],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("\"id\" = $1"))
        #expect(stmt.sql.contains("\"id\" = $2"))
        #expect(stmt.sql.contains(" OR "))
        #expect(!stmt.sql.contains("\"name\""))
        #expect(stmt.parameters.count == 2)
    }

    // MARK: - MSSQL DELETE with PK

    @Test("MSSQL delete with PK uses ? placeholder and PK-only WHERE")
    func testMSSQLDeleteWithPK() throws {
        let generator = try makeGenerator(databaseType: .mssql)
        let changes = [makeDeleteChange(rowIndex: 0, originalRow: ["1", "John", "john@test.com"])]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("DELETE FROM"))
        #expect(stmt.sql.contains("[users]"))
        #expect(stmt.sql.contains("[id] = ?"))
        #expect(!stmt.sql.contains("[name]"))
        #expect(!stmt.sql.contains("[email]"))
        #expect(stmt.parameters.count == 1)
    }

    // MARK: - ClickHouse DELETE with PK

    @Test("ClickHouse delete with PK uses ALTER TABLE DELETE")
    func testClickHouseDeleteWithPK() throws {
        let generator = try makeGenerator(databaseType: .clickhouse)
        let changes = [makeDeleteChange(rowIndex: 0, originalRow: ["1", "John", "john@test.com"])]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("ALTER TABLE"))
        #expect(stmt.sql.contains("DELETE WHERE"))
        #expect(stmt.sql.contains("`id`"))
        #expect(!stmt.sql.contains("`name`"))
        #expect(!stmt.sql.contains("`email`"))
    }

    // MARK: - UPDATE with PK

    @Test("PostgreSQL update with PK uses PK-only WHERE")
    func testPostgreSQLUpdateWithPK() throws {
        let generator = try makeGenerator(databaseType: .postgresql)
        let changes = [makeUpdateChange(
            rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Jane",
            originalRow: ["1", "John", "john@test.com"]
        )]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("UPDATE"))
        #expect(stmt.sql.contains("\"name\" = $1"))
        #expect(stmt.sql.contains("\"id\" = $2"))
        #expect(!stmt.sql.contains("\"email\""))
    }

    @Test("MSSQL update with PK uses PK-only WHERE")
    func testMSSQLUpdateWithPK() throws {
        let generator = try makeGenerator(databaseType: .mssql)
        let changes = [makeUpdateChange(
            rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Jane",
            originalRow: ["1", "John", "john@test.com"]
        )]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("UPDATE"))
        #expect(stmt.sql.contains("[name] = ?"))
        #expect(stmt.sql.contains("[id] = ?"))
        #expect(!stmt.sql.contains("[email]"))
    }

    // MARK: - Redshift DELETE with PK

    @Test("Redshift delete with PK uses $N placeholder and PK-only WHERE")
    func testRedshiftDeleteWithPK() throws {
        let generator = try makeGenerator(databaseType: .redshift)
        let changes = [makeDeleteChange(rowIndex: 0, originalRow: ["1", "John", "john@test.com"])]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        let stmt = statements[0]
        #expect(stmt.sql.contains("DELETE FROM"))
        #expect(stmt.sql.contains("\"id\" = $1"))
        #expect(!stmt.sql.contains("\"name\""))
        #expect(!stmt.sql.contains("\"email\""))
        #expect(stmt.parameters.count == 1)
    }
}
