//
//  TableQueryBuilderFilterTests.swift
//  TableProTests
//
//  Tests for TableQueryBuilder WHERE clause generation in fallback paths.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Table Query Builder - Filtered Query Fallback")
struct TableQueryBuilderFilteredQueryTests {
    private let builder = TableQueryBuilder(databaseType: .mysql)

    @Test("buildFilteredQuery with enabled filter produces WHERE clause")
    func filteredQueryWithEnabledFilter() {
        var filter = TableFilter()
        filter.columnName = "name"
        filter.filterOperator = .equal
        filter.value = "Alice"
        filter.isEnabled = true

        let query = builder.buildFilteredQuery(
            tableName: "users", filters: [filter]
        )
        #expect(query.contains("WHERE"))
        #expect(query.contains("name"))
        #expect(query.contains("Alice"))
    }

    @Test("buildFilteredQuery excludes disabled filters")
    func filteredQueryExcludesDisabledFilter() {
        var enabledFilter = TableFilter()
        enabledFilter.columnName = "name"
        enabledFilter.filterOperator = .equal
        enabledFilter.value = "Alice"
        enabledFilter.isEnabled = true

        var disabledFilter = TableFilter()
        disabledFilter.columnName = "age"
        disabledFilter.filterOperator = .equal
        disabledFilter.value = "30"
        disabledFilter.isEnabled = false

        let query = builder.buildFilteredQuery(
            tableName: "users", filters: [enabledFilter, disabledFilter]
        )
        #expect(query.contains("name"))
        #expect(!query.contains("age"))
    }

    @Test("buildFilteredQuery with no enabled filters produces no WHERE")
    func filteredQueryNoEnabledFilters() {
        var filter = TableFilter()
        filter.columnName = "name"
        filter.filterOperator = .equal
        filter.value = "Alice"
        filter.isEnabled = false

        let query = builder.buildFilteredQuery(
            tableName: "users", filters: [filter]
        )
        #expect(!query.contains("WHERE"))
    }

    @Test("buildFilteredQuery with empty filters produces no WHERE")
    func filteredQueryEmptyFilters() {
        let query = builder.buildFilteredQuery(
            tableName: "users", filters: []
        )
        #expect(!query.contains("WHERE"))
        #expect(query.contains("SELECT * FROM"))
    }
}

@Suite("Table Query Builder - Filtered Count")
struct TableQueryBuilderFilteredCountTests {
    private static let mysqlDialect = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexp, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit, paginationStyle: .limit
    )

    private var builder: TableQueryBuilder {
        TableQueryBuilder(databaseType: .mysql, dialect: Self.mysqlDialect)
    }

    private func makeFilter(_ column: String, _ value: String, _ op: FilterOperator = .equal) -> TableFilter {
        var filter = TableFilter()
        filter.columnName = column
        filter.filterOperator = op
        filter.value = value
        filter.isEnabled = true
        return filter
    }

    @Test("buildFilteredCountQuery wraps the filter in COUNT(*) WHERE without pagination")
    func filteredCountProducesWhere() {
        let query = builder.buildFilteredCountQuery(tableName: "users", filters: [makeFilter("name", "Alice")])
        #expect(query?.contains("SELECT COUNT(*) FROM") == true)
        #expect(query?.contains("WHERE") == true)
        #expect(query?.contains("name") == true)
        #expect(query?.contains("Alice") == true)
        #expect(query?.contains("LIMIT") == false)
        #expect(query?.contains("ORDER BY") == false)
    }

    @Test("buildFilteredCountQuery has no WHERE when no filters are enabled")
    func filteredCountNoEnabledFilters() {
        var disabled = makeFilter("name", "Alice")
        disabled.isEnabled = false
        let query = builder.buildFilteredCountQuery(tableName: "users", filters: [disabled])
        #expect(query?.contains("SELECT COUNT(*) FROM") == true)
        #expect(query?.contains("WHERE") == false)
    }

    @Test("buildFilteredCountQuery WHERE matches buildFilteredQuery WHERE")
    func countWhereMatchesDataWhere() {
        let filters = [makeFilter("age", "30", .greaterThan)]
        let countQuery = builder.buildFilteredCountQuery(tableName: "users", filters: filters) ?? ""
        let dataQuery = builder.buildFilteredQuery(tableName: "users", filters: filters)

        let countWhere = (countQuery.components(separatedBy: "WHERE").last ?? "").trimmingCharacters(in: .whitespaces)
        #expect(!countWhere.isEmpty)
        #expect(dataQuery.contains(countWhere))
    }

    @Test("buildFilteredCountQuery returns nil without a dialect")
    func filteredCountNilWithoutDialect() {
        let noDialect = TableQueryBuilder(databaseType: .mysql)
        #expect(noDialect.buildFilteredCountQuery(tableName: "users", filters: [makeFilter("name", "Alice")]) == nil)
    }
}

@Suite("Table Query Builder - Pagination Clause")
struct TableQueryBuilderPaginationTests {
    private static let trinoDialect = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexpLike, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .offsetFetch, offsetFetchOrderBy: ""
    )

    private static let mssqlDialect = SQLDialectDescriptor(
        identifierQuote: "[", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .unsupported, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit, paginationStyle: .offsetFetch
    )

    private static let mysqlDialect = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexp, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit, paginationStyle: .limit
    )

    private func builder(_ dialect: SQLDialectDescriptor) -> TableQueryBuilder {
        TableQueryBuilder(databaseType: .postgresql, dialect: dialect)
    }

    private func enabledFilter(_ column: String, _ value: String) -> TableFilter {
        var filter = TableFilter()
        filter.columnName = column
        filter.filterOperator = .equal
        filter.value = value
        filter.isEnabled = true
        return filter
    }

    @Test("Trino base query pages with OFFSET before FETCH FIRST and no ORDER BY")
    func trinoBaseQueryOffsetFetch() {
        let query = builder(Self.trinoDialect).buildBaseQuery(
            tableName: "pseudo_columns", schemaName: "jdbc", limit: 1_000, offset: 0
        )
        #expect(query.contains("\"jdbc\".\"pseudo_columns\""))
        #expect(query.contains("OFFSET 0 ROWS FETCH NEXT 1000 ROWS ONLY"))
        #expect(!query.contains("LIMIT"))
        #expect(!query.contains("ORDER BY"))
    }

    @Test("Trino filtered query keeps the WHERE and pages with OFFSET/FETCH FIRST")
    func trinoFilteredQueryOffsetFetch() {
        let query = builder(Self.trinoDialect).buildFilteredQuery(
            tableName: "orders", filters: [enabledFilter("status", "open")], limit: 500, offset: 500
        )
        #expect(query.contains("WHERE"))
        #expect(query.contains("OFFSET 500 ROWS FETCH NEXT 500 ROWS ONLY"))
        #expect(!query.contains("LIMIT"))
    }

    @Test("MSSQL base query injects its default ORDER BY before OFFSET/FETCH FIRST")
    func mssqlBaseQueryKeepsDefaultOrderBy() {
        let query = builder(Self.mssqlDialect).buildBaseQuery(tableName: "users", limit: 100, offset: 0)
        #expect(query.contains("ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 100 ROWS ONLY"))
        #expect(!query.contains("LIMIT"))
    }

    @Test("LIMIT-style dialect pages with LIMIT then OFFSET")
    func limitStyleBaseQuery() {
        let query = builder(Self.mysqlDialect).buildBaseQuery(tableName: "users", limit: 200, offset: 0)
        #expect(query.contains("LIMIT 200 OFFSET 0"))
        #expect(!query.contains("FETCH NEXT"))
    }
}

@Suite("Table Query Builder - NoSQL Nil Dialect Fallback")
struct TableQueryBuilderNoSQLTests {
    // MongoDB has no SQL dialect — should produce bare SELECT without WHERE
    private let builder = TableQueryBuilder(databaseType: .mongodb)

    @Test("NoSQL type produces no WHERE for filtered query")
    func noSqlFilteredQueryNoWhere() {
        var filter = TableFilter()
        filter.columnName = "name"
        filter.filterOperator = .equal
        filter.value = "Alice"
        filter.isEnabled = true

        let query = builder.buildFilteredQuery(
            tableName: "collection", filters: [filter]
        )
        #expect(!query.contains("WHERE"))
    }
}
