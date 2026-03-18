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

@Suite("Table Query Builder - Quick Search Fallback")
struct TableQueryBuilderQuickSearchTests {
    private let builder = TableQueryBuilder(databaseType: .mysql)

    @Test("buildQuickSearchQuery produces OR-joined LIKE conditions")
    func quickSearchProducesLike() {
        let query = builder.buildQuickSearchQuery(
            tableName: "users", searchText: "alice",
            columns: ["name", "email"]
        )
        #expect(query.contains("WHERE"))
        #expect(query.contains("LIKE"))
        #expect(query.contains("alice"))
    }

    @Test("buildQuickSearchQuery with empty search text produces no WHERE")
    func quickSearchEmptyText() {
        let query = builder.buildQuickSearchQuery(
            tableName: "users", searchText: "",
            columns: ["name", "email"]
        )
        #expect(!query.contains("WHERE"))
    }
}

@Suite("Table Query Builder - Combined Query Fallback")
struct TableQueryBuilderCombinedQueryTests {
    private let builder = TableQueryBuilder(databaseType: .mysql)

    @Test("buildCombinedQuery with filter and search produces both in WHERE")
    func combinedQueryFilterAndSearch() {
        var filter = TableFilter()
        filter.columnName = "status"
        filter.filterOperator = .equal
        filter.value = "active"
        filter.isEnabled = true

        let query = builder.buildCombinedQuery(
            tableName: "users", filters: [filter],
            searchText: "alice", searchColumns: ["name", "email"]
        )
        #expect(query.contains("WHERE"))
        #expect(query.contains("status"))
        #expect(query.contains("LIKE"))
        #expect(query.contains("AND"))
    }

    @Test("buildCombinedQuery excludes disabled filters")
    func combinedQueryExcludesDisabledFilter() {
        var disabledFilter = TableFilter()
        disabledFilter.columnName = "age"
        disabledFilter.filterOperator = .equal
        disabledFilter.value = "30"
        disabledFilter.isEnabled = false

        let query = builder.buildCombinedQuery(
            tableName: "users", filters: [disabledFilter],
            searchText: "alice", searchColumns: ["name"]
        )
        #expect(!query.contains("age"))
        #expect(query.contains("LIKE"))
    }
}

@Suite("Table Query Builder - PostgreSQL Quick Search CAST")
struct TableQueryBuilderPostgreSQLQuickSearchTests {
    private let builder = TableQueryBuilder(databaseType: .postgresql)

    @Test("PostgreSQL quick search uses CAST for LIKE on non-text columns")
    func postgresQuickSearchCast() {
        let query = builder.buildQuickSearchQuery(
            tableName: "users", searchText: "test",
            columns: ["id", "name"]
        )
        #expect(query.contains("CAST("))
        #expect(query.contains("AS TEXT)"))
        #expect(query.contains("LIKE"))
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

    @Test("NoSQL type produces no WHERE for quick search")
    func noSqlQuickSearchNoWhere() {
        let query = builder.buildQuickSearchQuery(
            tableName: "collection", searchText: "test",
            columns: ["field1"]
        )
        #expect(!query.contains("WHERE"))
    }
}
