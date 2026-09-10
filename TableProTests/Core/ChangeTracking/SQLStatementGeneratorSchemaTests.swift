//
//  SQLStatementGeneratorSchemaTests.swift
//  TableProTests
//
//  The generator can now address a table outside the schema the connection is
//  on, which is what a copy between two databases needs. A caller that names no
//  schema keeps the unqualified name it has always produced.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class SQLStatementGeneratorSchemaTests: XCTestCase {
    private func generator(schema: String?) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "orders",
            schemaName: schema,
            columns: ["id", "total"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            quoteIdentifier: { "\"\($0)\"" }
        )
    }

    func testASchemaQualifiesTheInsert() throws {
        let statement = try generator(schema: "sales")
            .insertStatement(columns: ["id"], values: [.text("1")])

        XCTAssertEqual(statement?.sql, "INSERT INTO \"sales\".\"orders\" (\"id\") VALUES ($1)")
    }

    /// Every existing caller passes no schema, so nothing that worked before changes shape.
    func testNoSchemaKeepsTheUnqualifiedName() throws {
        let statement = try generator(schema: nil)
            .insertStatement(columns: ["id"], values: [.text("1")])

        XCTAssertEqual(statement?.sql, "INSERT INTO \"orders\" (\"id\") VALUES ($1)")
    }

    func testAnEmptySchemaIsTreatedAsNoSchema() throws {
        XCTAssertEqual(try generator(schema: "").qualifiedTableName, "\"orders\"")
    }

    func testTheMultiRowInsertIsQualifiedToo() throws {
        let statement = try generator(schema: "sales")
            .insertStatement(columns: ["id", "total"], rows: [[.text("1"), .text("9")], [.text("2"), .text("8")]])

        XCTAssertEqual(
            statement?.sql,
            "INSERT INTO \"sales\".\"orders\" (\"id\", \"total\") VALUES ($1, $2), ($3, $4)"
        )
    }

    /// The copier hands the driver the batch flattened row-major, so the generator's own parameter
    /// order has to match or values land in the wrong columns.
    func testMultiRowParametersAreOrderedRowMajor() throws {
        let statement = try generator(schema: nil)
            .insertStatement(columns: ["id", "total"], rows: [[.text("1"), .text("9")], [.text("2"), .text("8")]])

        XCTAssertEqual(statement?.parameters.map { $0 as? String }, ["1", "9", "2", "8"])
    }

    func testDeleteAllRowsIsQualified() throws {
        XCTAssertEqual(
            try generator(schema: "sales").deleteAllRowsStatement(),
            "DELETE FROM \"sales\".\"orders\""
        )
    }
}
