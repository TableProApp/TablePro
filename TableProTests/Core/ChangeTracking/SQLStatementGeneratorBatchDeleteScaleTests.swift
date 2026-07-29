//
//  SQLStatementGeneratorBatchDeleteScaleTests.swift
//  TableProTests
//
//  Guards that multi-row DELETE generation stays bounded: N deleted rows collapse
//  into a small, fixed number of statements (one scan per chunk) instead of N
//  separate statements, and no statement exceeds the driver's bind-parameter cap.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Statement Generator: Batch Delete Scale")
struct SQLStatementGeneratorBatchDeleteScaleTests {
    private func makeGenerator(
        columns: [String],
        primaryKeyColumns: [String],
        databaseType: DatabaseType
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "events",
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            dialect: nil
        )
    }

    private func deleteChanges(count: Int, columns: [String]) -> [RowChange] {
        (0..<count).map { index in
            RowChange(
                rowIndex: index,
                type: .delete,
                cellChanges: [],
                originalRow: columns.indices.map { .text("\(index)-\($0)") }
            )
        }
    }

    @Test("Large primary-key selection stays a single statement")
    func testLargePKSelectionSingleStatement() throws {
        let generator = try makeGenerator(
            columns: ["id", "name"], primaryKeyColumns: ["id"], databaseType: .mysql
        )
        let changes = deleteChanges(count: 5_000, columns: ["id", "name"])

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: Set(0..<5_000),
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        #expect(statements[0].parameters.count == 5_000)
    }

    @Test("Primary-key selection chunks at the bind-parameter cap")
    func testPKSelectionChunksAtBindParameterCap() throws {
        let generator = try makeGenerator(
            columns: ["id", "name"], primaryKeyColumns: ["id"], databaseType: .mssql
        )
        let cap = generator.maxBindParameters
        let changes = deleteChanges(count: cap + 1, columns: ["id", "name"])

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: Set(0..<(cap + 1)),
            insertedRowIndices: []
        )

        #expect(statements.count == 2)
        #expect(statements.allSatisfy { $0.parameters.count <= cap })
        #expect(statements.reduce(0) { $0 + $1.parameters.count } == cap + 1)
    }

    @Test("Primary-key selection exactly at the cap stays one statement")
    func testPKSelectionExactlyAtCapSingleStatement() throws {
        let generator = try makeGenerator(
            columns: ["id"], primaryKeyColumns: ["id"], databaseType: .mssql
        )
        let cap = generator.maxBindParameters
        let changes = deleteChanges(count: cap, columns: ["id"])

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: Set(0..<cap),
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        #expect(statements[0].parameters.count == cap)
    }

    @Test("No-PK selection collapses into one OR'd statement, not one per row")
    func testNoPKSelectionSingleStatement() throws {
        let generator = try makeGenerator(
            columns: ["a", "b", "c"], primaryKeyColumns: [], databaseType: .mysql
        )
        let changes = deleteChanges(count: 1_000, columns: ["a", "b", "c"])

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: Set(0..<1_000),
            insertedRowIndices: []
        )

        #expect(statements.count == 1)
        #expect(statements[0].parameters.count == 3_000)
        #expect(statements[0].sql.contains(") OR ("))
    }

    @Test("No-PK selection chunks when full-column parameters exceed the cap")
    func testNoPKSelectionChunksAtBindParameterCap() throws {
        let columns = ["a", "b", "c"]
        let generator = try makeGenerator(
            columns: columns, primaryKeyColumns: [], databaseType: .mssql
        )
        let cap = generator.maxBindParameters
        let rowsPerChunk = cap / columns.count
        let rowCount = rowsPerChunk + 1
        let changes = deleteChanges(count: rowCount, columns: columns)

        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: Set(0..<rowCount),
            insertedRowIndices: []
        )

        #expect(statements.count == 2)
        #expect(statements.allSatisfy { $0.parameters.count <= cap })
        #expect(statements.reduce(0) { $0 + $1.parameters.count } == rowCount * columns.count)
    }
}
