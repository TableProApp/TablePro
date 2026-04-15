//
//  TableQueryBuilderSelectiveTests.swift
//  TableProTests
//
//  Tests for TableQueryBuilder selective column query building with exclusions.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Table Query Builder - Selective Column Queries")
struct TableQueryBuilderSelectiveTests {
    private let builder = TableQueryBuilder(databaseType: .mysql)

    @Test("No exclusions produces SELECT *")
    func noExclusionsSelectStar() {
        let query = builder.buildBaseQuery(tableName: "users")
        #expect(query.contains("SELECT *"))
    }

    @Test("Empty exclusions with columns still produces SELECT *")
    func emptyExclusionsSelectStar() {
        let query = builder.buildBaseQuery(
            tableName: "users",
            columns: ["id", "name"],
            columnExclusions: []
        )
        #expect(query.contains("SELECT *"))
    }

    @Test("BLOB exclusion produces LENGTH in column list")
    func blobExclusionWithLength() {
        let exclusions = [ColumnExclusion(columnName: "photo", placeholderExpression: "LENGTH(\"photo\")")]
        let query = builder.buildBaseQuery(
            tableName: "users",
            columns: ["id", "name", "photo"],
            columnExclusions: exclusions
        )
        #expect(!query.contains("SELECT *"))
        #expect(query.contains("LENGTH(\"photo\") AS"))
        #expect(query.contains("\"id\""))
        #expect(query.contains("\"name\""))
    }

    @Test("TEXT exclusion produces SUBSTRING in column list")
    func textExclusionWithSubstring() {
        let exclusions = [ColumnExclusion(
            columnName: "content",
            placeholderExpression: "SUBSTRING(\"content\", 1, 256)"
        )]
        let query = builder.buildBaseQuery(
            tableName: "posts",
            columns: ["id", "title", "content"],
            columnExclusions: exclusions
        )
        #expect(query.contains("SUBSTRING(\"content\", 1, 256) AS"))
        #expect(query.contains("\"id\""))
        #expect(query.contains("\"title\""))
    }

    @Test("Exclusions work with sort and pagination")
    func exclusionsWithSortAndPagination() {
        let exclusions = [ColumnExclusion(columnName: "data", placeholderExpression: "LENGTH(\"data\")")]
        let query = builder.buildBaseQuery(
            tableName: "files",
            columns: ["id", "name", "data"],
            limit: 50,
            offset: 100,
            columnExclusions: exclusions
        )
        #expect(query.contains("LENGTH(\"data\") AS"))
        #expect(query.contains("LIMIT 50"))
        #expect(query.contains("OFFSET 100"))
    }

    @Test("Filtered query with exclusions uses column list")
    func filteredQueryWithExclusions() {
        let exclusions = [ColumnExclusion(columnName: "photo", placeholderExpression: "LENGTH(\"photo\")")]
        let query = builder.buildFilteredQuery(
            tableName: "users",
            filters: [],
            columns: ["id", "name", "photo"],
            columnExclusions: exclusions
        )
        #expect(!query.contains("SELECT *"))
        #expect(query.contains("LENGTH(\"photo\") AS"))
    }

    // TODO: Re-enable when buildQuickSearchQuery API is restored
    #if false
    @Test("Quick search query with exclusions uses column list")
    func quickSearchWithExclusions() {
        let exclusions = [ColumnExclusion(columnName: "body", placeholderExpression: "SUBSTRING(\"body\", 1, 256)")]
        let query = builder.buildQuickSearchQuery(
            tableName: "posts",
            searchText: "hello",
            columns: ["id", "title", "body"],
            columnExclusions: exclusions
        )
        #expect(!query.contains("SELECT *"))
        #expect(query.contains("SUBSTRING(\"body\", 1, 256) AS"))
    }
    #endif

    // TODO: Re-enable when buildCombinedQuery API is restored
    #if false
    @Test("Combined query with exclusions uses column list")
    func combinedQueryWithExclusions() {
        let exclusions = [ColumnExclusion(columnName: "data", placeholderExpression: "LENGTH(\"data\")")]
        let query = builder.buildCombinedQuery(
            tableName: "files",
            filters: [],
            searchText: "test",
            searchColumns: ["name"],
            columns: ["id", "name", "data"],
            columnExclusions: exclusions
        )
        #expect(!query.contains("SELECT *"))
        #expect(query.contains("LENGTH(\"data\") AS"))
    }
    #endif

    @Test("Exclusions with no columns still produces SELECT *")
    func exclusionsButNoColumnsSelectStar() {
        let exclusions = [ColumnExclusion(columnName: "photo", placeholderExpression: "LENGTH(\"photo\")")]
        let query = builder.buildBaseQuery(
            tableName: "users",
            columns: [],
            columnExclusions: exclusions
        )
        #expect(query.contains("SELECT *"))
    }

    @Test("quoteIdentifier exposes identifier quoting")
    func quoteIdentifierPublic() {
        let quoted = builder.quoteIdentifier("my column")
        #expect(quoted == "\"my column\"")
    }
}
