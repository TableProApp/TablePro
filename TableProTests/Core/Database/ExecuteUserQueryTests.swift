//
//  ExecuteUserQueryTests.swift
//  TableProTests
//

import Foundation
import Testing
import TableProPluginKit
@testable import TablePro

@Suite("executeUserQuery applies row cap and respects user SQL")
struct ExecuteUserQueryTests {

    @Test("Caps result at rowCap and marks isTruncated when there are more rows than the cap")
    func capsAndMarksTruncated() async throws {
        let rows = (1...100).map { ["row_\($0)"] }
        let driver = StubPluginDriver(rows: rows)

        let result = try await driver.executeUserQuery(query: "SELECT * FROM t", rowCap: 5, parameters: nil)

        #expect(result.rows.count == 5)
        #expect(result.isTruncated)
        #expect(result.rows.first?.first == "row_1")
        #expect(result.rows.last?.first == "row_5")
    }

    @Test("Returns full result without truncation flag when row count is below cap")
    func belowCapNotTruncated() async throws {
        let rows = (1...3).map { ["row_\($0)"] }
        let driver = StubPluginDriver(rows: rows)

        let result = try await driver.executeUserQuery(query: "SELECT * FROM t", rowCap: 5, parameters: nil)

        #expect(result.rows.count == 3)
        #expect(!result.isTruncated)
    }

    @Test("Returns full result when rowCap is nil")
    func unlimitedCap() async throws {
        let rows = (1...100).map { ["row_\($0)"] }
        let driver = StubPluginDriver(rows: rows)

        let result = try await driver.executeUserQuery(query: "SELECT * FROM t", rowCap: nil, parameters: nil)

        #expect(result.rows.count == 100)
        #expect(!result.isTruncated)
    }

    @Test("Treats rowCap of 0 as unlimited and returns the full result")
    func zeroCapMeansUnlimited() async throws {
        let rows = (1...100).map { ["row_\($0)"] }
        let driver = StubPluginDriver(rows: rows)

        let result = try await driver.executeUserQuery(query: "SELECT * FROM t", rowCap: 0, parameters: nil)

        #expect(result.rows.count == 100)
        #expect(!result.isTruncated)
    }

    @Test("Passes user SQL through unchanged regardless of cap")
    func passesUserSqlUnchanged() async throws {
        let driver = StubPluginDriver(rows: [["x"]])
        let userSql = "SELECT uuid FROM TMTask WHERE status IN (2,3) ORDER BY stopDate DESC LIMIT 10"

        _ = try await driver.executeUserQuery(query: userSql, rowCap: 10_000, parameters: nil)

        #expect(driver.lastExecutedQuery == userSql)
        #expect(!driver.lastExecutedQuery!.contains("OFFSET"))
        #expect(driver.lastExecutedQuery!.contains("LIMIT 10"))
    }

    @Test("Passes user SQL with CTE unchanged")
    func passesCteUnchanged() async throws {
        let driver = StubPluginDriver(rows: [["x"]])
        let userSql = "WITH cte AS (SELECT * FROM t LIMIT 5) SELECT * FROM cte"

        _ = try await driver.executeUserQuery(query: userSql, rowCap: 10_000, parameters: nil)

        #expect(driver.lastExecutedQuery == userSql)
    }

    @Test("Routes parameterized queries through executeParameterized with the same SQL")
    func parameterizedRoutesCorrectly() async throws {
        let driver = StubPluginDriver(rows: [["x"]])
        let userSql = "SELECT * FROM t WHERE id = ? LIMIT 3"

        _ = try await driver.executeUserQuery(query: userSql, rowCap: 100, parameters: ["42"])

        #expect(driver.lastExecutedQuery == userSql)
        #expect(driver.lastParameters == ["42"])
    }

    @Test("Preserves status message and execution metadata when truncating")
    func preservesMetadata() async throws {
        let rows = (1...10).map { ["row_\($0)"] }
        let driver = StubPluginDriver(rows: rows, statusMessage: "warning: cache miss")

        let result = try await driver.executeUserQuery(query: "SELECT * FROM t", rowCap: 3, parameters: nil)

        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(result.statusMessage == "warning: cache miss")
        #expect(result.rowsAffected == 0)
    }
}

private final class StubPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private(set) var lastExecutedQuery: String?
    private(set) var lastParameters: [PluginCellValue]?
    private let rowsToReturn: [[PluginCellValue]]
    private let statusMessage: String?

    init(rows: [[String?]], statusMessage: String? = nil) {
        self.rowsToReturn = rows.map { row in row.map(PluginCellValue.fromOptional) }
        self.statusMessage = statusMessage
    }

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        lastExecutedQuery = query
        return PluginQueryResult(
            columns: ["col1"],
            columnTypeNames: ["TEXT"],
            rows: rowsToReturn,
            rowsAffected: 0,
            executionTime: 0.001,
            statusMessage: statusMessage
        )
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        lastExecutedQuery = query
        lastParameters = parameters
        return PluginQueryResult(
            columns: ["col1"],
            columnTypeNames: ["TEXT"],
            rows: rowsToReturn,
            rowsAffected: 0,
            executionTime: 0.001,
            statusMessage: statusMessage
        )
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}
