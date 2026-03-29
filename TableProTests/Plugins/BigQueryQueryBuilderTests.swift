//
//  BigQueryQueryBuilderTests.swift
//  TableProTests
//
//  Tests for BigQueryQueryBuilder (compiled via symlink from BigQueryDriverPlugin).
//

import Foundation
import Testing

@Suite("BigQueryQueryBuilder - Browse Query")
struct BigQueryQueryBuilderBrowseTests {
    @Test("Browse query returns tagged string")
    func browseReturnsTag() {
        let query = BigQueryQueryBuilder.encodeBrowseQuery(
            table: "users", dataset: "analytics", sortColumns: [], limit: 100, offset: 0
        )
        #expect(query.hasPrefix(BigQueryQueryBuilder.browseTag))
    }

    @Test("Browse query round-trips through decode")
    func browseRoundTrip() {
        let query = BigQueryQueryBuilder.encodeBrowseQuery(
            table: "orders", dataset: "sales", sortColumns: [(columnIndex: 0, ascending: true)],
            limit: 50, offset: 10
        )
        let params = BigQueryQueryBuilder.decode(query)
        #expect(params != nil)
        #expect(params?.table == "orders")
        #expect(params?.dataset == "sales")
        #expect(params?.limit == 50)
        #expect(params?.offset == 10)
        #expect(params?.sortColumns?.count == 1)
        #expect(params?.sortColumns?.first?.ascending == true)
    }
}

@Suite("BigQueryQueryBuilder - Filtered Query")
struct BigQueryQueryBuilderFilteredTests {
    @Test("Filtered query returns filter tag")
    func filteredReturnsTag() {
        let query = BigQueryQueryBuilder.encodeFilteredQuery(
            table: "users", dataset: "main",
            filters: [(column: "name", op: "=", value: "Alice")],
            logicMode: "AND", sortColumns: [], limit: 100, offset: 0
        )
        #expect(query.hasPrefix(BigQueryQueryBuilder.filterTag))
    }

    @Test("Filtered query preserves filters and logic mode")
    func filteredPreservesFilters() {
        let query = BigQueryQueryBuilder.encodeFilteredQuery(
            table: "events", dataset: "analytics",
            filters: [
                (column: "type", op: "=", value: "click"),
                (column: "count", op: ">", value: "10")
            ],
            logicMode: "OR", sortColumns: [], limit: 200, offset: 0
        )
        let params = BigQueryQueryBuilder.decode(query)
        #expect(params?.filters?.count == 2)
        #expect(params?.logicMode == "OR")
        #expect(params?.filters?[0].column == "type")
        #expect(params?.filters?[0].op == "=")
        #expect(params?.filters?[0].value == "click")
        #expect(params?.filters?[1].column == "count")
        #expect(params?.filters?[1].op == ">")
    }
}

@Suite("BigQueryQueryBuilder - Search Query")
struct BigQueryQueryBuilderSearchTests {
    @Test("Search query returns search tag")
    func searchReturnsTag() {
        let query = BigQueryQueryBuilder.encodeSearchQuery(
            table: "users", dataset: "main", searchText: "hello",
            searchColumns: ["name", "email"], sortColumns: [], limit: 100, offset: 0
        )
        #expect(query.hasPrefix(BigQueryQueryBuilder.searchTag))
    }

    @Test("Search query preserves search text and columns")
    func searchPreservesParams() {
        let query = BigQueryQueryBuilder.encodeSearchQuery(
            table: "logs", dataset: "infra", searchText: "error",
            searchColumns: ["message"], sortColumns: [], limit: 50, offset: 0
        )
        let params = BigQueryQueryBuilder.decode(query)
        #expect(params?.searchText == "error")
        #expect(params?.searchColumns == ["message"])
    }
}

@Suite("BigQueryQueryBuilder - Combined Query")
struct BigQueryQueryBuilderCombinedTests {
    @Test("Combined query returns combined tag")
    func combinedReturnsTag() {
        let query = BigQueryQueryBuilder.encodeCombinedQuery(
            table: "users", dataset: "main",
            filters: [(column: "active", op: "=", value: "true")],
            logicMode: "AND", searchText: "test",
            searchColumns: ["name"], sortColumns: [], limit: 100, offset: 0
        )
        #expect(query.hasPrefix(BigQueryQueryBuilder.combinedTag))
    }

    @Test("Combined query preserves both filters and search")
    func combinedPreservesBoth() {
        let query = BigQueryQueryBuilder.encodeCombinedQuery(
            table: "users", dataset: "main",
            filters: [(column: "status", op: "!=", value: "deleted")],
            logicMode: "AND", searchText: "alice",
            searchColumns: ["name", "email"], sortColumns: [], limit: 100, offset: 0
        )
        let params = BigQueryQueryBuilder.decode(query)
        #expect(params?.filters?.count == 1)
        #expect(params?.searchText == "alice")
        #expect(params?.searchColumns?.count == 2)
    }
}

@Suite("BigQueryQueryBuilder - isTaggedQuery")
struct BigQueryQueryBuilderIsTaggedTests {
    @Test("Tagged queries return true")
    func taggedQueriesDetected() {
        let browse = BigQueryQueryBuilder.encodeBrowseQuery(
            table: "t", dataset: "d", sortColumns: [], limit: 10, offset: 0
        )
        let filter = BigQueryQueryBuilder.encodeFilteredQuery(
            table: "t", dataset: "d", filters: [(column: "a", op: "=", value: "b")],
            logicMode: "AND", sortColumns: [], limit: 10, offset: 0
        )
        #expect(BigQueryQueryBuilder.isTaggedQuery(browse))
        #expect(BigQueryQueryBuilder.isTaggedQuery(filter))
    }

    @Test("Regular SQL returns false")
    func regularSqlNotTagged() {
        #expect(!BigQueryQueryBuilder.isTaggedQuery("SELECT * FROM users"))
        #expect(!BigQueryQueryBuilder.isTaggedQuery("INSERT INTO t VALUES (1)"))
    }

    @Test("Decode returns nil for non-tagged query")
    func decodeNonTagged() {
        #expect(BigQueryQueryBuilder.decode("SELECT 1") == nil)
    }
}

@Suite("BigQueryQueryBuilder - SQL Generation")
struct BigQueryQueryBuilderSQLTests {
    @Test("Browse SQL generates correct SELECT")
    func browseSql() {
        let params = BigQueryQueryParams(
            table: "users", dataset: "main", sortColumns: nil,
            limit: 100, offset: 0, filters: nil, logicMode: nil,
            searchText: nil, searchColumns: nil
        )
        let sql = BigQueryQueryBuilder.buildSQL(from: params, projectId: "proj", columns: ["id", "name"])
        #expect(sql == "SELECT * FROM `proj.main.users` LIMIT 100 OFFSET 0")
    }

    @Test("Filtered SQL generates WHERE clause")
    func filteredSql() {
        let params = BigQueryQueryParams(
            table: "users", dataset: "main", sortColumns: nil,
            limit: 100, offset: 0,
            filters: [BigQueryFilterSpec(column: "status", op: "=", value: "active")],
            logicMode: "AND", searchText: nil, searchColumns: nil
        )
        let sql = BigQueryQueryBuilder.buildSQL(from: params, projectId: "proj", columns: ["id", "status"])
        #expect(sql.contains("WHERE `status` = 'active'"))
    }

    @Test("Sort columns generate ORDER BY")
    func sortSql() {
        let params = BigQueryQueryParams(
            table: "events", dataset: "analytics",
            sortColumns: [.init(columnIndex: 1, ascending: false)],
            limit: 50, offset: 0, filters: nil, logicMode: nil,
            searchText: nil, searchColumns: nil
        )
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params, projectId: "proj", columns: ["id", "created_at"]
        )
        #expect(sql.contains("ORDER BY `created_at` DESC"))
    }

    @Test("Search generates LIKE clauses with OR")
    func searchSql() {
        let params = BigQueryQueryParams(
            table: "users", dataset: "main", sortColumns: nil,
            limit: 100, offset: 0, filters: nil, logicMode: nil,
            searchText: "test", searchColumns: ["name", "email"]
        )
        let sql = BigQueryQueryBuilder.buildSQL(from: params, projectId: "proj", columns: ["id", "name", "email"])
        #expect(sql.contains("CAST(`name` AS STRING) LIKE '%test%'"))
        #expect(sql.contains(" OR "))
    }

    @Test("Count SQL omits LIMIT")
    func countSql() {
        let params = BigQueryQueryParams(
            table: "users", dataset: "main", sortColumns: nil,
            limit: 100, offset: 0, filters: nil, logicMode: nil,
            searchText: nil, searchColumns: nil
        )
        let sql = BigQueryQueryBuilder.buildCountSQL(from: params, projectId: "proj", columns: [])
        #expect(sql == "SELECT COUNT(*) FROM `proj.main.users`")
        #expect(!sql.contains("LIMIT"))
    }

    @Test("Single quote in filter value is escaped")
    func filterEscaping() {
        let params = BigQueryQueryParams(
            table: "users", dataset: "main", sortColumns: nil,
            limit: 10, offset: 0,
            filters: [BigQueryFilterSpec(column: "name", op: "=", value: "O'Brien")],
            logicMode: "AND", searchText: nil, searchColumns: nil
        )
        let sql = BigQueryQueryBuilder.buildSQL(from: params, projectId: "proj", columns: ["name"])
        #expect(sql.contains("O''Brien"))
    }

    @Test("IN operator escapes individual values")
    func inOperatorEscaping() {
        let params = BigQueryQueryParams(
            table: "t", dataset: "d", sortColumns: nil,
            limit: 10, offset: 0,
            filters: [BigQueryFilterSpec(column: "status", op: "IN", value: "a, b, c")],
            logicMode: "AND", searchText: nil, searchColumns: nil
        )
        let sql = BigQueryQueryBuilder.buildSQL(from: params, projectId: "proj", columns: ["status"])
        #expect(sql.contains("IN ('a', 'b', 'c')"))
    }
}
