//
//  SQLiteTemporaryTableTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct SQLiteTemporaryTableTests {
    private func withDriver(_ body: (SQLitePluginDriver) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-temporary-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: url.path
        ))
        try await driver.connect()
        defer { driver.disconnect() }
        try await body(driver)
    }

    @Test("The session lists its own temporary tables and views, and no others")
    func listsTheSessionsTemporaryObjects() async throws {
        try await withDriver { driver in
            #expect(driver.capabilities.contains(.temporaryTables))
            _ = try await driver.execute(query: "CREATE TABLE kept (a INT)")
            #expect(try await driver.fetchTemporaryTables().isEmpty)

            _ = try await driver.execute(query: "CREATE TEMP TABLE t AS SELECT 1 AS x")
            _ = try await driver.execute(query: "CREATE TEMP VIEW v AS SELECT x FROM t")

            let listed = try await driver.fetchTemporaryTables()
            #expect(listed.map { $0.name } == ["t", "v"])
            #expect(listed.map { $0.type } == ["TABLE", "VIEW"])
            #expect(try await driver.fetchTables(schema: nil).map { $0.name } == ["kept"])
        }
    }

    @Test("A temporary table's definition is read from the temp schema, ahead of a main table of the same name")
    func definitionResolvesLikeTheBareName() async throws {
        try await withDriver { driver in
            _ = try await driver.execute(query: "CREATE TABLE t (main_col INT)")
            _ = try await driver.execute(
                query: """
                    CREATE TEMP TABLE t (
                        temp_col INT, doubled INT GENERATED ALWAYS AS (temp_col * 2),
                        CONSTRAINT positive CHECK (temp_col > 0)
                    )
                    """
            )

            let ddl = try await driver.fetchTableDDL(table: "t", schema: nil)
            #expect(ddl.contains("temp_col"))
            #expect(!ddl.contains("main_col"))
            #expect(try await driver.fetchCheckConstraints(table: "t", schema: nil).count == 1)
            let columns = try await driver.fetchColumns(table: "t", schema: nil)
            #expect(columns.first { $0.name == "doubled" }?.generationExpression == "temp_col * 2")
        }
    }

    @Test("A temporary table's index DDL is its own, never the hidden main table's")
    func indexDefinitionsFollowTheResolvedTable() async throws {
        try await withDriver { driver in
            _ = try await driver.execute(query: "CREATE TABLE t (main_col INT)")
            _ = try await driver.execute(query: "CREATE INDEX main_idx ON t (main_col)")
            #expect(try await driver.fetchIndexDDL(table: "t", schema: nil).count == 1)

            _ = try await driver.execute(query: "CREATE TEMP TABLE t (temp_col INT)")
            _ = try await driver.execute(query: "CREATE INDEX temp.temp_idx ON t (temp_col)")

            let ddl = try await driver.fetchIndexDDL(table: "t", schema: nil)
            #expect(ddl.count == 1)
            #expect(ddl.first?.contains("temp_idx") == true)
        }
    }

    @Test("A temporary table's triggers and index expressions are its own")
    func triggersAndIndexesFollowTheResolvedTable() async throws {
        try await withDriver { driver in
            _ = try await driver.execute(query: "CREATE TABLE t (main_col INT)")
            _ = try await driver.execute(query: "CREATE TRIGGER main_trigger AFTER INSERT ON t BEGIN SELECT 1; END")
            _ = try await driver.execute(query: "CREATE TEMP TABLE t (temp_col TEXT)")
            _ = try await driver.execute(query: "CREATE TEMP TRIGGER temp_trigger AFTER INSERT ON t BEGIN SELECT 1; END")
            _ = try await driver.execute(query: "CREATE INDEX temp.lower_idx ON t (lower(temp_col)) WHERE temp_col IS NOT NULL")

            let triggers = try await driver.fetchTriggers(table: "t", schema: nil)
            #expect(triggers.map { $0.name } == ["temp_trigger"])
            let indexes = try await driver.fetchIndexes(table: "t", schema: nil)
            let index = try #require(indexes.first { $0.name == "lower_idx" })
            #expect(index.columns.contains { $0.contains("lower") })
            #expect(index.whereClause != nil)
        }
    }
}
