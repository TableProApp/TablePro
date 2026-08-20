//
//  SchemaMetadataGeneratedColumnTests.swift
//  TableProTests
//
//  The generated-column flag has to survive the driver-to-app schema parse, or
//  the grid and the statement generator never learn a column is computed.
//

import Foundation
@testable import TablePro
import Testing

@MainActor @Suite("Schema metadata generated columns")
struct SchemaMetadataGeneratedColumnTests {
    private func makeSchema(_ columns: [ColumnInfo]) -> FetchedTableSchema {
        FetchedTableSchema(columns: columns, foreignKeys: nil, approximateRowCount: nil)
    }

    @Test("A generated column is carried into the parsed metadata")
    func generatedColumnIsParsed() {
        let schema = makeSchema([
            ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true),
            ColumnInfo(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false),
            ColumnInfo(
                name: "full_name",
                dataType: "TEXT",
                isNullable: true,
                isPrimaryKey: false,
                isGenerated: true
            )
        ])

        let parsed = QueryExecutor.parseSchemaMetadata(schema)

        #expect(parsed.generatedColumns == ["full_name"])
        #expect(parsed.primaryKeyColumns == ["id"])
    }

    @Test("A table with no generated columns parses to an empty set")
    func noGeneratedColumns() {
        let schema = makeSchema([
            ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)
        ])

        #expect(QueryExecutor.parseSchemaMetadata(schema).generatedColumns.isEmpty)
    }

    @Test("ColumnInfo defaults to not generated")
    func columnInfoDefaultsToNotGenerated() {
        let column = ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)
        #expect(!column.isGenerated)
    }
}
