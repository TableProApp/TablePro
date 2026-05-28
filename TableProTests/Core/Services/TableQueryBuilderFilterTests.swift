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
