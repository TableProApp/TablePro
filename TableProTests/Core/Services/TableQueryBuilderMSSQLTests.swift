//
//  TableQueryBuilderMSSQLTests.swift
//  TableProTests
//
//  Tests for TableQueryBuilder with databaseType: .mssql
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
@Suite("Table Query Builder MSSQL")
struct TableQueryBuilderMSSQLTests {
    private let builder: TableQueryBuilder

    init() {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let dialect = PluginManager.shared.sqlDialect(for: .mssql)
        let dialectQuote = dialect.map(quoteIdentifierFromDialect)
        self.builder = TableQueryBuilder(
            databaseType: .mssql,
            pluginDriver: PluginManager.shared.queryBuildingDriver(for: .mssql),
            dialect: dialect,
            dialectQuote: dialectQuote
        )
    }

    // MARK: - Base Query Tests

    @Test("Base query with no sort uses ORDER BY SELECT NULL and OFFSET FETCH NEXT syntax")
    func baseQueryNoSort() {
        let query = builder.buildBaseQuery(tableName: "users")
        #expect(query.contains("ORDER BY (SELECT NULL)"))
        #expect(query.contains("OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY"))
    }

    @Test("Base query uses bracket-quoted table name")
    func baseQueryBracketQuotedTable() {
        let query = builder.buildBaseQuery(tableName: "users")
        #expect(query.contains("SELECT * FROM [users]"))
    }

    @Test("Base query with offset applies correct OFFSET value")
    func baseQueryWithOffset() {
        let query = builder.buildBaseQuery(tableName: "users", offset: 200)
        #expect(query.contains("OFFSET 200 ROWS FETCH NEXT 200 ROWS ONLY"))
    }

    @Test("Base query with custom limit applies correct FETCH NEXT value")
    func baseQueryWithCustomLimit() {
        let query = builder.buildBaseQuery(tableName: "users", limit: 50)
        #expect(query.contains("FETCH NEXT 50 ROWS ONLY"))
    }

    @Test("Base query does not use MySQL-style LIMIT OFFSET syntax")
    func baseQueryNoMySQLLimitSyntax() {
        let query = builder.buildBaseQuery(tableName: "users")
        let normalized = query.uppercased()
        #expect(!normalized.contains(" LIMIT "))
    }

    @Test("Base query with table name containing bracket escapes it")
    func baseQueryBracketInTableName() {
        let query = builder.buildBaseQuery(tableName: "user]s")
        #expect(query.contains("[user]]s]"))
    }

    // MARK: - Filtered Query Tests

    @Test("Filtered query without filters uses ORDER BY SELECT NULL")
    func filteredQueryNoFilters() {
        let query = builder.buildFilteredQuery(tableName: "users", filters: [])
        #expect(query.contains("ORDER BY (SELECT NULL)"))
        #expect(query.contains("OFFSET"))
        #expect(query.contains("FETCH NEXT"))
    }

    @Test("Filtered query with filters contains WHERE clause and OFFSET FETCH NEXT")
    func filteredQueryWithFilters() {
        let filters = [
            TestFixtures.makeTableFilter(column: "name", op: .equal, value: "Alice")
        ]
        let query = builder.buildFilteredQuery(tableName: "users", filters: filters)
        #expect(query.contains("WHERE"))
        #expect(query.contains("[name]"))
        #expect(query.contains("OFFSET"))
        #expect(query.contains("FETCH NEXT"))
    }

    @Test("Filtered query does not use MySQL-style LIMIT OFFSET syntax")
    func filteredQueryNoMySQLSyntax() {
        let query = builder.buildFilteredQuery(tableName: "users", filters: [])
        let normalized = query.uppercased()
        #expect(!normalized.contains(" LIMIT "))
    }
}
