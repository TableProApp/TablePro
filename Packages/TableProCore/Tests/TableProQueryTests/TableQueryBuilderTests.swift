import Testing
import Foundation
@testable import TableProQuery
@testable import TableProModels

@Suite("TableQueryBuilder Tests")
struct TableQueryBuilderTests {
    private var dialect: QueryDialectDescriptor {
        QueryDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            paginationStyle: .limit
        )
    }

    @Test("Basic browse query")
    func basicBrowse() {
        let builder = TableQueryBuilder(dialect: dialect)
        let query = builder.buildBrowseQuery(tableName: "users", limit: 100, offset: 0)
        #expect(query == "SELECT * FROM \"users\" LIMIT 100 OFFSET 0")
    }

    @Test("Browse query with sort")
    func browseWithSort() {
        let builder = TableQueryBuilder(dialect: dialect)
        let sort = SortState(columns: [SortColumn(name: "name", ascending: true)])
        let query = builder.buildBrowseQuery(tableName: "users", sortState: sort, limit: 50, offset: 10)
        #expect(query.contains("ORDER BY \"name\" ASC"))
        #expect(query.contains("LIMIT 50 OFFSET 10"))
    }

    @Test("Browse query with descending sort")
    func browseWithDescSort() {
        let builder = TableQueryBuilder(dialect: dialect)
        let sort = SortState(columns: [SortColumn(name: "created_at", ascending: false)])
        let query = builder.buildBrowseQuery(tableName: "posts", sortState: sort, limit: 20, offset: 0)
        #expect(query.contains("ORDER BY \"created_at\" DESC"))
    }

    @Test("Offset-fetch pagination style")
    func offsetFetchPagination() {
        let offsetDialect = QueryDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            paginationStyle: .offsetFetch,
            offsetFetchOrderBy: "ORDER BY (SELECT NULL)"
        )
        let builder = TableQueryBuilder(dialect: offsetDialect)
        let query = builder.buildBrowseQuery(tableName: "users", limit: 50, offset: 100)
        #expect(query.contains("OFFSET 100 ROWS FETCH NEXT 50 ROWS ONLY"))
    }

    @Test("Filtered query generates WHERE clause")
    func filteredQuery() {
        let builder = TableQueryBuilder(dialect: dialect)
        let filters = [TableFilter(columnName: "active", filterOperator: .equal, value: "1")]
        let query = builder.buildFilteredQuery(
            tableName: "users",
            filters: filters,
            limit: 100,
            offset: 0
        )
        #expect(query.contains("WHERE"))
        #expect(query.contains("\"active\""))
    }

    @Test("No dialect falls back to LIMIT pagination")
    func noDialectFallback() {
        let builder = TableQueryBuilder()
        let query = builder.buildBrowseQuery(tableName: "test", limit: 10, offset: 5)
        #expect(query.contains("LIMIT 10 OFFSET 5"))
    }

    @Test("Table name with special characters is quoted")
    func specialTableName() {
        let builder = TableQueryBuilder(dialect: dialect)
        let query = builder.buildBrowseQuery(tableName: "my table", limit: 10, offset: 0)
        #expect(query.contains("\"my table\""))
    }

    @Test("MSSQL dialect uses brackets and offset fetch")
    func mssqlDialectBrowseQuery() {
        let builder = TableQueryBuilder(dialect: SQLDialectFactory.dialect(for: .mssql))
        let query = builder.buildBrowseQuery(tableName: "users]archive", limit: 10, offset: 5)
        #expect(query == "SELECT * FROM [users]]archive] ORDER BY (SELECT NULL) OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY")
    }
}
