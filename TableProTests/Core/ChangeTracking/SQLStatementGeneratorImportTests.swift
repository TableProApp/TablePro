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

@Suite("SQL Statement Generator - row import")
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

    @Test("deleteAllRowsStatement quotes the table identifier per dialect")
    func testDeleteAllRows() throws {
        #expect(try makeGenerator(databaseType: .mysql).deleteAllRowsStatement() == "DELETE FROM `users`")
        #expect(try makeGenerator(databaseType: .postgresql).deleteAllRowsStatement() == "DELETE FROM \"users\"")
    }
}
