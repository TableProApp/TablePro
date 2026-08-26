//
//  SQLStatementGeneratorGeneratedColumnTests.swift
//  TableProTests
//
//  A server-computed column rejects any written value, so it must never reach
//  an INSERT or an UPDATE no matter which path builds the statement.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Statement Generator generated columns")
struct SQLStatementGeneratorGeneratedColumnTests {
    private func makeGenerator(
        generatedColumns: Set<String> = ["full_name"]
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "users",
            columns: ["id", "name", "full_name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: generatedColumns,
            dialect: nil
        )
    }

    @Test("Insert from stored row data omits a generated column")
    func insertFromStoredDataOmitsGeneratedColumn() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [0: ["1", "John", "John Doe"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let statement = try #require(statements.first)
        #expect(!statement.sql.contains("full_name"))
        #expect(statement.sql.contains("`name`"))
        #expect(statement.parameters.count == 2)
    }

    @Test("Insert from cell changes omits a generated column")
    func insertFromCellChangesOmitsGeneratedColumn() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .insert,
                cellChanges: [
                    CellChange(columnIndex: 1, columnName: "name", oldValue: .null, newValue: "John"),
                    CellChange(
                        columnIndex: 2,
                        columnName: "full_name",
                        oldValue: .null,
                        newValue: "John Doe"
                    )
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

        let statement = try #require(statements.first)
        #expect(!statement.sql.contains("full_name"))
        #expect(statement.sql.contains("`name`"))
    }

    @Test("Update drops a generated column from the SET clause")
    func updateDropsGeneratedColumn() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(columnIndex: 1, columnName: "name", oldValue: "John", newValue: "Johnny"),
                    CellChange(
                        columnIndex: 2,
                        columnName: "full_name",
                        oldValue: "John Doe",
                        newValue: "Johnny Doe"
                    )
                ],
                originalRow: ["1", "John", "John Doe"]
            )
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        let statement = try #require(statements.first)
        #expect(!statement.sql.contains("full_name"))
        #expect(statement.sql.contains("`name` ="))
    }

    @Test("An update touching only a generated column produces no statement")
    func updateOfOnlyGeneratedColumnProducesNothing() throws {
        let generator = try makeGenerator()
        let changes: [RowChange] = [
            RowChange(
                rowIndex: 0,
                type: .update,
                cellChanges: [
                    CellChange(
                        columnIndex: 2,
                        columnName: "full_name",
                        oldValue: "John Doe",
                        newValue: "Johnny Doe"
                    )
                ],
                originalRow: ["1", "John", "John Doe"]
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

    @Test("A table with no generated columns is unaffected")
    func tableWithoutGeneratedColumnsIsUnaffected() throws {
        let generator = try makeGenerator(generatedColumns: [])
        let changes: [RowChange] = [
            RowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        ]

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [0: ["1", "John", "John Doe"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let statement = try #require(statements.first)
        #expect(statement.sql.contains("full_name"))
        #expect(statement.parameters.count == 3)
    }
}
