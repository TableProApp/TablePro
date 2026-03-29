//
//  TableQueryBuilderFilterTests.swift
//  TableProTests
//
//  Tests for TableQueryBuilder WHERE clause generation in fallback paths.
//

import Foundation
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
