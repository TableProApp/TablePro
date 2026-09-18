import Foundation
import TableProPluginKit
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
            filters: [PluginQueryFilter(column: "name", op: "=", value: "Alice")],
            logicMode: "AND", sortColumns: [], limit: 100, offset: 0
        )
        #expect(query.hasPrefix(BigQueryQueryBuilder.filterTag))
    }

    @Test("Filtered query preserves filters and logic mode")
    func filteredPreservesFilters() {
        let query = BigQueryQueryBuilder.encodeFilteredQuery(
            table: "events", dataset: "analytics",
            filters: [
                PluginQueryFilter(column: "type", op: "=", value: "click"),
                PluginQueryFilter(column: "count", op: ">", value: "10")
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
            filters: [PluginQueryFilter(column: "active", op: "=", value: "true")],
            logicMode: "AND", searchText: "test",
            searchColumns: ["name"], sortColumns: [], limit: 100, offset: 0
        )
        #expect(query.hasPrefix(BigQueryQueryBuilder.combinedTag))
    }

    @Test("Combined query preserves both filters and search")
    func combinedPreservesBoth() {
        let query = BigQueryQueryBuilder.encodeCombinedQuery(
            table: "users", dataset: "main",
            filters: [PluginQueryFilter(column: "status", op: "!=", value: "deleted")],
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
            table: "t", dataset: "d", filters: [PluginQueryFilter(column: "a", op: "=", value: "b")],
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
    private func params(
        table: String = "users",
        dataset: String = "main",
        sortColumns: [BigQueryQueryParams.SortColumn]? = nil,
        filters: [BigQueryFilterSpec]? = nil,
        logicMode: String? = nil,
        searchText: String? = nil,
        searchColumns: [String]? = nil,
        columns: [String]? = nil
    ) -> BigQueryQueryParams {
        BigQueryQueryParams(
            table: table, dataset: dataset, sortColumns: sortColumns,
            limit: 100, offset: 0, filters: filters, logicMode: logicMode,
            searchText: searchText, searchColumns: searchColumns, columns: columns
        )
    }

    @Test("Browse SQL generates correct SELECT")
    func browseSql() {
        let sql = BigQueryQueryBuilder.buildSQL(from: params(columns: ["id", "name"]), projectId: "proj")
        #expect(sql == "SELECT * FROM `proj`.`main`.`users` LIMIT 100 OFFSET 0")
    }

    @Test("Filtered SQL generates WHERE clause")
    func filteredSql() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(filters: [BigQueryFilterSpec(column: "status", op: "=", value: "active")], logicMode: "AND"),
            projectId: "proj"
        )
        #expect(sql.contains("WHERE (`status` = 'active')"))
    }

    @Test("Sort columns resolve against the column names carried in the tag")
    func sortSql() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(sortColumns: [.init(columnIndex: 1, ascending: false)], columns: ["id", "created_at"]),
            projectId: "proj"
        )
        #expect(sql.contains("ORDER BY `created_at` DESC"))
    }

    @Test("A tag without column names drops the sort rather than guessing")
    func sortWithoutColumns() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(sortColumns: [.init(columnIndex: 0, ascending: true)]),
            projectId: "proj"
        )
        #expect(!sql.contains("ORDER BY"))
    }

    @Test("Search generates LIKE clauses with OR")
    func searchSql() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(searchText: "test", searchColumns: ["name", "email"]),
            projectId: "proj"
        )
        #expect(sql.contains("CAST(`name` AS STRING) LIKE '%test%'"))
        #expect(sql.contains(" OR "))
    }

    @Test("Search falls back to the tag's column names")
    func searchUsesTagColumns() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(searchText: "x", columns: ["a", "b"]),
            projectId: "proj"
        )
        #expect(sql.contains("CAST(`a` AS STRING) LIKE '%x%' OR CAST(`b` AS STRING) LIKE '%x%'"))
    }

    @Test("Count SQL omits LIMIT")
    func countSql() {
        let sql = BigQueryQueryBuilder.buildCountSQL(from: params(), projectId: "proj")
        #expect(sql == "SELECT COUNT(*) FROM `proj`.`main`.`users`")
        #expect(!sql.contains("LIMIT"))
    }

    @Test("A single quote in a filter value is escaped with a backslash")
    func filterEscaping() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(filters: [BigQueryFilterSpec(column: "name", op: "=", value: "O'Brien")]),
            projectId: "proj"
        )
        #expect(sql.contains("`name` = 'O\\'Brien'"))
        #expect(!sql.contains("O''Brien"))
    }

    @Test("A value that tries to close its literal stays one literal")
    func filterInjectionStaysOneLiteral() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(filters: [BigQueryFilterSpec(column: "name", op: "=", value: "x\\' OR TRUE --")]),
            projectId: "proj"
        )
        #expect(sql.contains("`name` = 'x\\\\\\' OR TRUE --'"))
    }

    @Test("Newlines and NUL in a value are escaped")
    func filterControlCharacters() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(filters: [BigQueryFilterSpec(column: "note", op: "=", value: "a\nb\u{0}c")]),
            projectId: "proj"
        )
        #expect(sql.contains("'a\\nb\\x00c'"))
    }

    @Test("CONTAINS escapes LIKE wildcards in the value")
    func containsEscapesWildcards() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(filters: [BigQueryFilterSpec(column: "code", op: "CONTAINS", value: "50%_off")]),
            projectId: "proj"
        )
        #expect(sql.contains("CAST(`code` AS STRING) LIKE '%50\\\\%\\\\_off%'"))
    }

    @Test("IN operator escapes individual values")
    func inOperatorEscaping() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(filters: [BigQueryFilterSpec(column: "status", op: "IN", value: "a, b', c")]),
            projectId: "proj"
        )
        #expect(sql.contains("IN ('a', 'b\\'', 'c')"))
    }

    @Test("OR filters are grouped before the search condition")
    func orFiltersAreGrouped() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(
                filters: [
                    BigQueryFilterSpec(column: "a", op: "=", value: "1", kind: "integer"),
                    BigQueryFilterSpec(column: "b", op: "=", value: "2", kind: "integer")
                ],
                logicMode: "OR",
                searchText: "z",
                searchColumns: ["c"]
            ),
            projectId: "proj"
        )
        #expect(sql.contains("WHERE (`a` = 1 OR `b` = 2) AND (CAST(`c` AS STRING) LIKE '%z%')"))
    }

    @Test("BETWEEN uses the separate upper bound")
    func betweenUsesSecondValue() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(filters: [
                BigQueryFilterSpec(column: "n", op: "BETWEEN", value: "1", kind: "integer", secondValue: "9")
            ]),
            projectId: "proj"
        )
        #expect(sql.contains("`n` BETWEEN 1 AND 9"))
    }

    @Test("A raw SQL filter is wrapped in parentheses")
    func rawFilter() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(filters: [
                BigQueryFilterSpec(column: BigQueryQueryBuilder.rawFilterColumn, op: "=", value: "a > 1 OR b < 2")
            ]),
            projectId: "proj"
        )
        #expect(sql.contains("WHERE ((a > 1 OR b < 2))"))
    }

    @Test("A backtick in a column name is escaped, not dropped")
    func identifierEscaping() {
        let sql = BigQueryQueryBuilder.buildSQL(
            from: params(filters: [BigQueryFilterSpec(column: "we`ird", op: "IS NULL", value: "")]),
            projectId: "proj"
        )
        #expect(sql.contains("`we\\`ird` IS NULL"))
    }
}

@Suite("BigQueryQueryBuilder - Column names in the tag")
struct BigQueryQueryBuilderTagColumnTests {
    @Test("Browse tags carry the column names")
    func browseCarriesColumns() {
        let query = BigQueryQueryBuilder.encodeBrowseQuery(
            table: "t", dataset: "d", sortColumns: [(columnIndex: 1, ascending: true)],
            limit: 10, offset: 0, columns: ["id", "name"]
        )
        let params = BigQueryQueryBuilder.decode(query)
        #expect(params?.columns == ["id", "name"])
        let sql = params.map { BigQueryQueryBuilder.buildSQL(from: $0, projectId: "p") } ?? ""
        #expect(sql.contains("ORDER BY `name` ASC"))
    }

    @Test("Filter tags carry the column names and the upper bound")
    func filterCarriesColumns() {
        let query = BigQueryQueryBuilder.encodeFilteredQuery(
            table: "t", dataset: "d",
            filters: [PluginQueryFilter(column: "n", op: "BETWEEN", value: "1", secondValue: "5", elementScope: nil)],
            logicMode: "AND", sortColumns: [], limit: 10, offset: 0, columns: ["n"]
        )
        let params = BigQueryQueryBuilder.decode(query)
        #expect(params?.columns == ["n"])
        #expect(params?.filters?.first?.secondValue == "5")
    }

    @Test("A tag written before column names existed still decodes")
    func legacyTagDecodes() throws {
        let json = #"{"table":"t","dataset":"d","limit":5,"offset":0}"#
        let query = BigQueryQueryBuilder.browseTag + Data(json.utf8).base64EncodedString()
        let params = try #require(BigQueryQueryBuilder.decode(query))
        #expect(params.columns == nil)
        let sql = BigQueryQueryBuilder.buildSQL(from: params, projectId: "p")
        #expect(sql == "SELECT * FROM `p`.`d`.`t` LIMIT 5 OFFSET 0")
    }
}

@Suite("BigQueryQueryBuilder - Exact Count")
struct BigQueryQueryBuilderExactCountTests {
    @Test("A count without filters has no WHERE clause")
    func countWithoutFilters() {
        let sql = BigQueryQueryBuilder.countSQL(
            projectId: "proj", dataset: "main", table: "users", filters: [], logicMode: "AND"
        )
        #expect(sql == "SELECT COUNT(*) FROM `proj`.`main`.`users`")
    }

    @Test("A quote in a filter value is escaped the GoogleSQL way, never doubled")
    func countEscapesQuotes() {
        let sql = BigQueryQueryBuilder.countSQL(
            projectId: "proj",
            dataset: "main",
            table: "users",
            filters: [PluginQueryFilter(column: "name", op: "=", value: "O'Brien")],
            logicMode: "AND",
            columnKinds: ["name": .text]
        )
        #expect(sql == "SELECT COUNT(*) FROM `proj`.`main`.`users` WHERE (`name` = 'O\\'Brien')")
        #expect(!sql.contains("''"))
    }

    @Test("Column kinds type the literals and the logic mode joins the filters")
    func countUsesKindsAndLogicMode() {
        let sql = BigQueryQueryBuilder.countSQL(
            projectId: "proj",
            dataset: "main",
            table: "users",
            filters: [
                PluginQueryFilter(column: "code", op: "=", value: "42"),
                PluginQueryFilter(column: "age", op: ">", value: "30")
            ],
            logicMode: "OR",
            columnKinds: ["code": .text, "age": .integer]
        )
        #expect(sql == "SELECT COUNT(*) FROM `proj`.`main`.`users` WHERE (`code` = '42' OR `age` > 30)")
    }
}
