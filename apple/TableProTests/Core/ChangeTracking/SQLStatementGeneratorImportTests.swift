//
//  SQLStatementGeneratorImportTests.swift
//  TableProTests
//
//  Tests for the row-import INSERT/DELETE helpers used by data importers.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct SQLStatementGeneratorImportTests {
    private func makeGenerator(
        table: String = "users",
        databaseType: DatabaseType = .mysql
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: table,
            columns: [],
            primaryKeyColumns: [],
            databaseType: databaseType
        )
    }

    @Test("insertStatement parameterizes every value (MySQL)")
    func testInsertParameterizesValues() throws {
        let generator = try makeGenerator()
        let stmt = try #require(generator.insertStatement(columns: ["id", "name"], values: ["1", .text("John")]))
        #expect(stmt.sql == "INSERT INTO `users` (`id`, `name`) VALUES (?, ?)")
        #expect(stmt.parameters.count == 2)
        #expect(stmt.parameters[0] as? String == "1")
        #expect(stmt.parameters[1] as? String == "John")
    }

    @Test("insertStatement binds SQL-looking data instead of interpolating it")
    func testInsertDoesNotInterpolate() throws {
        let generator = try makeGenerator()
        let injection = "'); DROP TABLE users;--"
        let stmt = try #require(generator.insertStatement(columns: ["name"], values: [.text(injection)]))
        #expect(stmt.sql == "INSERT INTO `users` (`name`) VALUES (?)")
        #expect(stmt.parameters[0] as? String == injection)
    }

    @Test("insertStatement uses positional placeholders for PostgreSQL")
    func testInsertPostgres() throws {
        let generator = try makeGenerator(databaseType: .postgresql)
        let stmt = try #require(generator.insertStatement(columns: ["id", "name"], values: ["1", .text("a")]))
        #expect(stmt.sql == "INSERT INTO \"users\" (\"id\", \"name\") VALUES ($1, $2)")
    }

    @Test("insertStatement passes null through as a nil bind")
    func testInsertNull() throws {
        let generator = try makeGenerator()
        let stmt = try #require(generator.insertStatement(columns: ["deleted_at"], values: [.null]))
        #expect(stmt.parameters.count == 1)
        #expect(stmt.parameters[0] == nil)
    }

    @Test("insertStatement returns nil for empty or mismatched input")
    func testInsertGuards() throws {
        let generator = try makeGenerator()
        #expect(generator.insertStatement(columns: [], values: []) == nil)
        #expect(generator.insertStatement(columns: ["a"], values: ["1", "2"]) == nil)
    }

    @Test("multi-row insertStatement emits one VALUES tuple per row with shared columns (MySQL)")
    func testMultiRowInsertMySQL() throws {
        let generator = try makeGenerator()
        let stmt = try #require(generator.insertStatement(
            columns: ["id", "name"],
            rows: [["1", .text("a")], ["2", .text("b")]]
        ))
        #expect(stmt.sql == "INSERT INTO `users` (`id`, `name`) VALUES (?, ?), (?, ?)")
        #expect(stmt.parameters.count == 4)
        #expect(stmt.parameters[2] as? String == "2")
        #expect(stmt.parameters[3] as? String == "b")
    }

    @Test("multi-row insertStatement numbers placeholders across rows for PostgreSQL")
    func testMultiRowInsertPostgres() throws {
        let generator = try makeGenerator(databaseType: .postgresql)
        let stmt = try #require(generator.insertStatement(
            columns: ["id", "name"],
            rows: [["1", .text("a")], ["2", .text("b")]]
        ))
        #expect(stmt.sql == "INSERT INTO \"users\" (\"id\", \"name\") VALUES ($1, $2), ($3, $4)")
    }

    @Test("multi-row insertStatement returns nil for empty rows or arity mismatch")
    func testMultiRowInsertGuards() throws {
        let generator = try makeGenerator()
        #expect(generator.insertStatement(columns: ["a"], rows: []) == nil)
        #expect(generator.insertStatement(columns: ["a", "b"], rows: [["1"]]) == nil)
    }

    @Test("maxBindParameters reflects each engine's protocol limit")
    func testMaxBindParameters() throws {
        #expect(try makeGenerator(databaseType: .postgresql).maxBindParameters == 65_535)
        #expect(try makeGenerator(databaseType: .sqlite).maxBindParameters == 32_766)
        #expect(try makeGenerator(databaseType: .mssql).maxBindParameters == 2_100)
        #expect(try makeGenerator(databaseType: .mysql).maxBindParameters == 65_535)
    }

    @Test("keyMatchCountStatement asks one count per key, tagged with its position")
    func testKeyMatchCountStatement() throws {
        let stmt = try #require(try makeGenerator(databaseType: .postgresql).keyMatchCountStatement(
            keyColumns: ["tenant", "id"],
            keys: [[.text("t1"), .text("1")], [.text("t1"), .null]]
        ))
        #expect(stmt.sql == """
            SELECT 0, COUNT(*) FROM "users" WHERE "tenant" = $1 AND "id" = $2 \
            UNION ALL SELECT 1, COUNT(*) FROM "users" WHERE "tenant" = $3 AND "id" = $4
            """)
        #expect(stmt.parameters.count == 4)
        #expect(stmt.parameters[1] as? String == "1")
        #expect(stmt.parameters[3] == nil)
    }

    @Test("keyMatchCountStatement returns nil for no keys or a key of the wrong width")
    func testKeyMatchCountStatementGuards() throws {
        let generator = try makeGenerator()
        #expect(generator.keyMatchCountStatement(keyColumns: ["id"], keys: []) == nil)
        #expect(generator.keyMatchCountStatement(keyColumns: [], keys: [[]]) == nil)
        #expect(generator.keyMatchCountStatement(keyColumns: ["id"], keys: [["1", "2"]]) == nil)
    }

    @Test("keyedUpdateStatement sets the given columns and matches on the key")
    func testKeyedUpdateStatement() throws {
        let stmt = try #require(try makeGenerator().keyedUpdateStatement(
            columns: ["name", "note"],
            values: [.text("Ada"), .null],
            keyColumns: ["id"],
            keyValues: ["7"]
        ))
        #expect(stmt.sql == "UPDATE `users` SET `name` = ?, `note` = ? WHERE `id` = ?")
        #expect(stmt.parameters.count == 3)
        #expect(stmt.parameters[0] as? String == "Ada")
        #expect(stmt.parameters[1] == nil)
        #expect(stmt.parameters[2] as? String == "7")
    }

    @Test("keyedUpdateStatement numbers PostgreSQL placeholders across SET and WHERE")
    func testKeyedUpdateStatementPostgres() throws {
        let stmt = try #require(try makeGenerator(databaseType: .postgresql).keyedUpdateStatement(
            columns: ["name"],
            values: [.text("Ada")],
            keyColumns: ["tenant", "id"],
            keyValues: [.text("t1"), "7"]
        ))
        #expect(stmt.sql == "UPDATE \"users\" SET \"name\" = $1 WHERE \"tenant\" = $2 AND \"id\" = $3")
    }

    @Test("keyedUpdateStatement returns nil with nothing to set or no key")
    func testKeyedUpdateStatementGuards() throws {
        let generator = try makeGenerator()
        #expect(generator.keyedUpdateStatement(columns: [], values: [], keyColumns: ["id"], keyValues: ["1"]) == nil)
        #expect(generator.keyedUpdateStatement(columns: ["a"], values: ["1"], keyColumns: [], keyValues: []) == nil)
        #expect(generator.keyedUpdateStatement(columns: ["a"], values: [], keyColumns: ["id"], keyValues: ["1"]) == nil)
    }

    @Test("deleteAllRowsStatement quotes the table identifier per dialect")
    func testDeleteAllRows() throws {
        #expect(try makeGenerator(databaseType: .mysql).deleteAllRowsStatement() == "DELETE FROM `users`")
        #expect(try makeGenerator(databaseType: .postgresql).deleteAllRowsStatement() == "DELETE FROM \"users\"")
    }
}
