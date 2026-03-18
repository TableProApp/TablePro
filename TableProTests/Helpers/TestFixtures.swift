//
//  TestFixtures.swift
//  TableProTests
//
//  Shared test data and factory methods for creating test objects
//

import Foundation
import Testing
@testable import TablePro

enum TestFixtures {
    // MARK: - Database Types

    static let allDatabaseTypes: [DatabaseType] = [
        .mysql, .mariadb, .postgresql, .sqlite, .redshift,
        .mongodb, .redis, .clickhouse
    ]

    // MARK: - ClickHouse Connection Fixture

    static let clickhouseConnection = DatabaseConnection(
        name: "ClickHouse Test",
        host: "localhost",
        port: 8_123,
        database: "default",
        username: "default",
        type: .clickhouse
    )

    // MARK: - Factory Methods

    static func makeTableFilter(
        column: String = "id",
        op: FilterOperator = .equal,
        value: String = "1",
        secondValue: String? = nil,
        rawSQL: String? = nil
    ) -> TableFilter {
        return TableFilter(
            id: UUID(),
            columnName: column,
            filterOperator: op,
            value: value,
            secondValue: secondValue,
            isSelected: true,
            isEnabled: true,
            rawSQL: rawSQL
        )
    }

    static func makeCellChange(
        row: Int = 0,
        col: Int = 0,
        colName: String = "column",
        old: String? = nil,
        new: String? = "value"
    ) -> CellChange {
        return CellChange(
            rowIndex: row,
            columnIndex: col,
            columnName: colName,
            oldValue: old,
            newValue: new
        )
    }

    static func makeRowChange(
        row: Int = 0,
        type: ChangeType = .update,
        cells: [CellChange] = [],
        originalRow: [String?]? = nil
    ) -> RowChange {
        return RowChange(
            rowIndex: row,
            type: type,
            cellChanges: cells,
            originalRow: originalRow
        )
    }

    static func makeColumnInfo(
        name: String = "id",
        dataType: String = "INT",
        isNullable: Bool = false,
        isPrimaryKey: Bool = true
    ) -> ColumnInfo {
        return ColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            defaultValue: nil,
            extra: nil,
            charset: nil,
            collation: nil,
            comment: nil
        )
    }

    static func makeTableInfo(
        name: String = "test_table",
        type: TableInfo.TableType = .table
    ) -> TableInfo {
        return TableInfo(
            name: name,
            type: type,
            rowCount: 0
        )
    }

    static func makeEditableColumn(
        name: String = "id",
        dataType: String = "INT",
        isNullable: Bool = false,
        autoIncrement: Bool = false,
        isPrimaryKey: Bool = false
    ) -> EditableColumnDefinition {
        return EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            defaultValue: nil,
            autoIncrement: autoIncrement,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: isPrimaryKey
        )
    }

    static func makeEditableIndex(
        name: String = "idx_test",
        columns: [String] = ["id"],
        isUnique: Bool = false,
        isPrimary: Bool = false
    ) -> EditableIndexDefinition {
        return EditableIndexDefinition(
            id: UUID(),
            name: name,
            columns: columns,
            type: .btree,
            isUnique: isUnique,
            isPrimary: isPrimary,
            comment: nil
        )
    }

    static func makeEditableForeignKey(
        name: String = "fk_test",
        columns: [String] = ["id"],
        refTable: String = "ref_table",
        refColumns: [String] = ["id"]
    ) -> EditableForeignKeyDefinition {
        return EditableForeignKeyDefinition(
            id: UUID(),
            name: name,
            columns: columns,
            referencedTable: refTable,
            referencedColumns: refColumns,
            onDelete: .noAction,
            onUpdate: .noAction
        )
    }

    static func makeHistoryEntry(
        id: UUID = UUID(),
        query: String = "SELECT * FROM users",
        connectionId: UUID = UUID(),
        databaseName: String = "testdb",
        executionTime: TimeInterval = 0.05,
        rowCount: Int = 10,
        wasSuccessful: Bool = true,
        errorMessage: String? = nil
    ) -> QueryHistoryEntry {
        return QueryHistoryEntry(
            id: id,
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage
        )
    }

    static func makeConnection(
        id: UUID = UUID(),
        name: String = "Test",
        database: String = "testdb",
        type: DatabaseType = .mysql
    ) -> DatabaseConnection {
        DatabaseConnection(
            id: id,
            name: name,
            database: database,
            type: type
        )
    }

    static func makeQueryResultRows(count: Int, columns: [String] = ["id", "name", "email"]) -> [QueryResultRow] {
        (0..<count).map { i in
            QueryResultRow(id: i, values: columns.indices.map { col in "\(columns[col])_\(i)" })
        }
    }

    static func makeInMemoryRowProvider(rowCount: Int = 3, columns: [String] = ["id", "name", "email"]) -> InMemoryRowProvider {
        let rows = makeQueryResultRows(count: rowCount, columns: columns)
        return InMemoryRowProvider(rows: rows, columns: columns)
    }

    static func makeForeignKeyInfo(
        name: String = "fk_user",
        column: String = "user_id",
        referencedTable: String = "users",
        referencedColumn: String = "id",
        onDelete: String = "CASCADE",
        onUpdate: String = "NO ACTION"
    ) -> ForeignKeyInfo {
        ForeignKeyInfo(
            name: name,
            column: column,
            referencedTable: referencedTable,
            referencedColumn: referencedColumn,
            onDelete: onDelete,
            onUpdate: onUpdate
        )
    }
}
