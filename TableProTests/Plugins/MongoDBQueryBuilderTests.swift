//
//  MongoDBQueryBuilderTests.swift
//  TableProTests
//
//  Tests for MongoDBQueryBuilder (compiled via symlink from MongoDBDriverPlugin).
//

import Foundation
import Testing
import TableProPluginKit

@Suite("MongoDB Query Builder")
struct MongoDBQueryBuilderTests {
    private let builder = MongoDBQueryBuilder()

    // MARK: - Base Query

    @Test("Base query with defaults")
    func baseQueryDefaults() {
        let query = builder.buildBaseQuery(collection: "users")
        #expect(query == "db.users.find({}).limit(200)")
    }

    @Test("Base query with custom limit")
    func baseQueryCustomLimit() {
        let query = builder.buildBaseQuery(collection: "users", limit: 50)
        #expect(query == "db.users.find({}).limit(50)")
    }

    @Test("Base query with offset")
    func baseQueryWithOffset() {
        let query = builder.buildBaseQuery(collection: "users", limit: 50, offset: 100)
        #expect(query == "db.users.find({}).skip(100).limit(50)")
    }

    @Test("Base query with zero offset omits skip")
    func baseQueryZeroOffset() {
        let query = builder.buildBaseQuery(collection: "users", limit: 200, offset: 0)
        #expect(!query.contains(".skip("))
    }

    @Test("Base query with ascending sort")
    func baseQueryAscendingSort() {
        let query = builder.buildBaseQuery(
            collection: "users",
            sortColumns: [(columnIndex: 0, ascending: true)],
            columns: ["name", "email"]
        )
        #expect(query.contains(".sort({\"name\": 1})"))
        #expect(query.contains(".limit(200)"))
    }

    @Test("Base query with descending sort")
    func baseQueryDescendingSort() {
        let query = builder.buildBaseQuery(
            collection: "users",
            sortColumns: [(columnIndex: 1, ascending: false)],
            columns: ["name", "email"]
        )
        #expect(query.contains(".sort({\"email\": -1})"))
    }

    @Test("Base query with multiple sort columns")
    func baseQueryMultiSort() {
        let query = builder.buildBaseQuery(
            collection: "users",
            sortColumns: [(columnIndex: 0, ascending: true), (columnIndex: 1, ascending: false)],
            columns: ["name", "age"]
        )
        #expect(query.contains(".sort({\"name\": 1, \"age\": -1})"))
    }

    @Test("Base query with out-of-bounds sort column index is ignored")
    func baseQueryOutOfBoundsSortIndex() {
        let query = builder.buildBaseQuery(
            collection: "users",
            sortColumns: [(columnIndex: 5, ascending: true)],
            columns: ["name"]
        )
        #expect(!query.contains(".sort("))
    }

    @Test("Collection with special characters uses bracket notation")
    func collectionWithSpecialChars() {
        let query = builder.buildBaseQuery(collection: "my.collection")
        #expect(query.hasPrefix("db[\"my.collection\"]"))
    }

    @Test("Collection starting with number uses bracket notation")
    func collectionStartingWithNumber() {
        let query = builder.buildBaseQuery(collection: "123abc")
        #expect(query.hasPrefix("db[\"123abc\"]"))
    }

    @Test("Collection with simple name uses dot notation")
    func collectionSimpleName() {
        let query = builder.buildBaseQuery(collection: "users")
        #expect(query.hasPrefix("db.users"))
    }

    @Test("Collection with underscore uses dot notation")
    func collectionWithUnderscore() {
        let query = builder.buildBaseQuery(collection: "my_collection")
        #expect(query.hasPrefix("db.my_collection"))
    }

    // MARK: - Filtered Query

    @Test("Filtered query with equals operator")
    func filteredQueryEquals() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "name", op: "=", value: "Alice")]
        )
        #expect(query.contains("\"name\": \"Alice\""))
    }

    @Test("Filtered query with numeric equals")
    func filteredQueryNumericEquals() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "age", op: "=", value: "30")]
        )
        #expect(query.contains("\"age\": 30"))
    }

    @Test("Filtered query with boolean value")
    func filteredQueryBoolean() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "active", op: "=", value: "true")]
        )
        #expect(query.contains("\"active\": true"))
    }

    @Test("Filtered query with multiple filters AND logic")
    func filteredQueryMultipleAnd() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [
                (column: "name", op: "=", value: "Alice"),
                (column: "age", op: ">", value: "25")
            ],
            logicMode: "and"
        )
        #expect(query.contains("$and"))
        #expect(query.contains("\"name\": \"Alice\""))
        #expect(query.contains("\"age\": {\"$gt\": 25}"))
    }

    @Test("Filtered query with multiple filters OR logic")
    func filteredQueryMultipleOr() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [
                (column: "name", op: "=", value: "Alice"),
                (column: "name", op: "=", value: "Bob")
            ],
            logicMode: "or"
        )
        #expect(query.contains("$or"))
    }

    @Test("Filtered query with single filter omits logic operator")
    func filteredQuerySingleFilter() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "name", op: "=", value: "Alice")]
        )
        #expect(!query.contains("$and"))
        #expect(!query.contains("$or"))
    }

    @Test("Filtered query with not-equal operator")
    func filteredQueryNotEqual() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "status", op: "!=", value: "inactive")]
        )
        #expect(query.contains("\"$ne\": \"inactive\""))
    }

    @Test("Filtered query with greater-than-or-equal operator")
    func filteredQueryGte() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "age", op: ">=", value: "18")]
        )
        #expect(query.contains("\"$gte\": 18"))
    }

    @Test("Filtered query with less-than operator")
    func filteredQueryLt() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "score", op: "<", value: "100")]
        )
        #expect(query.contains("\"$lt\": 100"))
    }

    @Test("Filtered query with CONTAINS operator")
    func filteredQueryContains() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "name", op: "CONTAINS", value: "ali")]
        )
        #expect(query.contains("\"$regex\": \"ali\""))
        #expect(query.contains("\"$options\": \"i\""))
    }

    @Test("Filtered query with NOT CONTAINS operator")
    func filteredQueryNotContains() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "name", op: "NOT CONTAINS", value: "test")]
        )
        #expect(query.contains("\"$not\""))
        #expect(query.contains("\"$regex\": \"test\""))
    }

    @Test("Filtered query with STARTS WITH operator")
    func filteredQueryStartsWith() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "name", op: "STARTS WITH", value: "Al")]
        )
        #expect(query.contains("\"$regex\": \"^Al\""))
    }

    @Test("Filtered query with ENDS WITH operator")
    func filteredQueryEndsWith() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "name", op: "ENDS WITH", value: "ice")]
        )
        #expect(query.contains("\"$regex\": \"ice$\""))
    }

    @Test("Filtered query with IS NULL operator")
    func filteredQueryIsNull() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "email", op: "IS NULL", value: "")]
        )
        #expect(query.contains("\"email\": null"))
    }

    @Test("Filtered query with IS NOT NULL operator")
    func filteredQueryIsNotNull() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "email", op: "IS NOT NULL", value: "")]
        )
        #expect(query.contains("\"email\": {\"$ne\": null}"))
    }

    @Test("Filtered query with IS EMPTY operator")
    func filteredQueryIsEmpty() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "bio", op: "IS EMPTY", value: "")]
        )
        #expect(query.contains("\"bio\": \"\""))
    }

    @Test("Filtered query with IS NOT EMPTY operator")
    func filteredQueryIsNotEmpty() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "bio", op: "IS NOT EMPTY", value: "")]
        )
        #expect(query.contains("\"bio\": {\"$ne\": \"\"}"))
    }

    @Test("Filtered query with REGEX operator")
    func filteredQueryRegex() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "name", op: "REGEX", value: "^[A-Z].*")]
        )
        #expect(query.contains("\"$regex\": \"^[A-Z].*\""))
    }

    @Test("Filtered query with sort and offset")
    func filteredQueryWithSortAndOffset() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            filters: [(column: "name", op: "=", value: "Alice")],
            sortColumns: [(columnIndex: 0, ascending: true)],
            columns: ["name"],
            limit: 50,
            offset: 25
        )
        #expect(query.contains(".sort({\"name\": 1})"))
        #expect(query.contains(".skip(25)"))
        #expect(query.contains(".limit(50)"))
    }

    // MARK: - Filter Document

    @Test("Filter document with IN operator")
    func filterDocumentIn() {
        let doc = builder.buildFilterDocument(
            from: [(column: "status", op: "IN", value: "active, inactive, pending")]
        )
        #expect(doc.contains("\"$in\""))
        #expect(doc.contains("\"active\""))
        #expect(doc.contains("\"inactive\""))
        #expect(doc.contains("\"pending\""))
    }

    @Test("Filter document with IN operator numeric values")
    func filterDocumentInNumeric() {
        let doc = builder.buildFilterDocument(
            from: [(column: "age", op: "IN", value: "18, 25, 30")]
        )
        #expect(doc.contains("\"$in\": [18, 25, 30]"))
    }

    @Test("Filter document with NOT IN operator")
    func filterDocumentNotIn() {
        let doc = builder.buildFilterDocument(
            from: [(column: "status", op: "NOT IN", value: "banned, deleted")]
        )
        #expect(doc.contains("\"$nin\""))
        #expect(doc.contains("\"banned\""))
        #expect(doc.contains("\"deleted\""))
    }

    @Test("Filter document with BETWEEN operator")
    func filterDocumentBetween() {
        let doc = builder.buildFilterDocument(
            from: [(column: "age", op: "BETWEEN", value: "18, 65")]
        )
        #expect(doc.contains("\"$gte\": 18"))
        #expect(doc.contains("\"$lte\": 65"))
    }

    @Test("Filter document with BETWEEN invalid format returns empty")
    func filterDocumentBetweenInvalid() {
        let doc = builder.buildFilterDocument(
            from: [(column: "age", op: "BETWEEN", value: "18")]
        )
        #expect(doc == "{}")
    }

    @Test("Filter document with empty filters returns empty object")
    func filterDocumentEmpty() {
        let doc = builder.buildFilterDocument(from: [])
        #expect(doc == "{}")
    }

    @Test("Filter document with unknown operator returns empty object")
    func filterDocumentUnknownOp() {
        let doc = builder.buildFilterDocument(
            from: [(column: "x", op: "UNKNOWN_OP", value: "y")]
        )
        #expect(doc == "{}")
    }

    @Test("Filter document with float value")
    func filterDocumentFloat() {
        let doc = builder.buildFilterDocument(
            from: [(column: "price", op: "=", value: "19.99")]
        )
        #expect(doc.contains("\"price\": 19.99"))
    }

    @Test("Filter document with null literal")
    func filterDocumentNullLiteral() {
        let doc = builder.buildFilterDocument(
            from: [(column: "field", op: "=", value: "null")]
        )
        #expect(doc.contains("\"field\": null"))
    }

    // MARK: - Combined Query

    @Test("Combined query wraps filter and search in $and")
    func combinedQuery() {
        let query = builder.buildCombinedQuery(
            collection: "users",
            filters: [(column: "age", op: ">", value: "25")],
            searchText: "john",
            searchColumns: ["name", "email"]
        )
        #expect(query.contains("$and"))
        #expect(query.contains("\"$gt\": 25"))
        #expect(query.contains("$or"))
        #expect(query.contains("\"$regex\": \"john\""))
    }

    @Test("Combined query with sort and offset")
    func combinedQueryWithSortAndOffset() {
        let query = builder.buildCombinedQuery(
            collection: "users",
            filters: [(column: "age", op: ">", value: "18")],
            searchText: "test",
            searchColumns: ["name"],
            sortColumns: [(columnIndex: 0, ascending: false)],
            columns: ["name"],
            limit: 100,
            offset: 50
        )
        #expect(query.contains(".sort({\"name\": -1})"))
        #expect(query.contains(".skip(50)"))
        #expect(query.contains(".limit(100)"))
    }

    // MARK: - Count Query

    @Test("Count query with default filter")
    func countQueryDefault() {
        let query = builder.buildCountQuery(collection: "users")
        #expect(query == "db.users.countDocuments({})")
    }

    @Test("Count query with custom filter")
    func countQueryWithFilter() {
        let query = builder.buildCountQuery(collection: "users", filterJson: "{\"active\": true}")
        #expect(query == "db.users.countDocuments({\"active\": true})")
    }

    @Test("Count query with special collection name")
    func countQuerySpecialCollection() {
        let query = builder.buildCountQuery(collection: "my.data")
        #expect(query.hasPrefix("db[\"my.data\"]"))
        #expect(query.contains(".countDocuments({})"))
    }
}
