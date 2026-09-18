//
//  MongoDBQueryBuilderTests.swift
//  TableProTests
//
//  Tests for MongoDBQueryBuilder (compiled via symlink from MongoDBDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

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

    @Test("Collection with special characters goes through getCollection")
    func collectionWithSpecialChars() {
        let query = builder.buildBaseQuery(collection: "my.collection")
        #expect(query.hasPrefix("db.getCollection(\"my.collection\")"))
    }

    @Test("Collection starting with number goes through getCollection")
    func collectionStartingWithNumber() {
        let query = builder.buildBaseQuery(collection: "123abc")
        #expect(query.hasPrefix("db.getCollection(\"123abc\")"))
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
            queryFilters: [PluginQueryFilter(column: "name", op: "=", value: "Alice")]
        )
        #expect(query.contains("\"name\": \"Alice\""))
    }

    @Test("Filtered query with numeric equals")
    func filteredQueryNumericEquals() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "age", op: "=", value: "30")]
        )
        #expect(query.contains("\"age\": 30"))
    }

    @Test("Filtered query with boolean value")
    func filteredQueryBoolean() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "active", op: "=", value: "true")]
        )
        #expect(query.contains("\"active\": true"))
    }

    @Test("Filtered query with multiple filters AND logic")
    func filteredQueryMultipleAnd() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [
                PluginQueryFilter(column: "name", op: "=", value: "Alice"),
                PluginQueryFilter(column: "age", op: ">", value: "25")
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
            queryFilters: [
                PluginQueryFilter(column: "name", op: "=", value: "Alice"),
                PluginQueryFilter(column: "name", op: "=", value: "Bob")
            ],
            logicMode: "or"
        )
        #expect(query.contains("$or"))
    }

    @Test("Filtered query with single filter omits logic operator")
    func filteredQuerySingleFilter() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "name", op: "=", value: "Alice")]
        )
        #expect(!query.contains("$and"))
        #expect(!query.contains("$or"))
    }

    @Test("Filtered query with not-equal operator")
    func filteredQueryNotEqual() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "status", op: "!=", value: "inactive")]
        )
        #expect(query.contains("\"$ne\": \"inactive\""))
    }

    @Test("Filtered query with greater-than-or-equal operator")
    func filteredQueryGte() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "age", op: ">=", value: "18")]
        )
        #expect(query.contains("\"$gte\": 18"))
    }

    @Test("Filtered query with less-than operator")
    func filteredQueryLt() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "score", op: "<", value: "100")]
        )
        #expect(query.contains("\"$lt\": 100"))
    }

    @Test("Filtered query with CONTAINS operator")
    func filteredQueryContains() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [
                PluginQueryFilter(column: "name", op: "CONTAINS", value: "ali", isCaseSensitive: false)
            ]
        )
        #expect(query.contains("\"$regex\": \"ali\""))
        #expect(query.contains("\"$options\": \"i\""))
    }

    @Test("Filtered query with CONTAINS matching case drops the ignore-case option")
    func filteredQueryContainsMatchingCase() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "name", op: "CONTAINS", value: "ali")]
        )
        #expect(query.contains("\"$regex\": \"ali\""))
        #expect(!query.contains("$options"))
    }

    @Test("Filtered query with NOT CONTAINS operator")
    func filteredQueryNotContains() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "name", op: "NOT CONTAINS", value: "test")]
        )
        #expect(query.contains("\"$not\""))
        #expect(query.contains("\"$regex\": \"test\""))
    }

    @Test("Filtered query with STARTS WITH operator")
    func filteredQueryStartsWith() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "name", op: "STARTS WITH", value: "Al")]
        )
        #expect(query.contains("\"$regex\": \"^Al\""))
    }

    @Test("Filtered query with ENDS WITH operator")
    func filteredQueryEndsWith() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "name", op: "ENDS WITH", value: "ice")]
        )
        #expect(query.contains("\"$regex\": \"ice$\""))
    }

    @Test("Filtered query with IS NULL operator")
    func filteredQueryIsNull() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "email", op: "IS NULL", value: "")]
        )
        #expect(query.contains("\"email\": null"))
    }

    @Test("Filtered query with IS NOT NULL operator")
    func filteredQueryIsNotNull() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "email", op: "IS NOT NULL", value: "")]
        )
        #expect(query.contains("\"email\": {\"$ne\": null}"))
    }

    @Test("Filtered query with IS EMPTY operator")
    func filteredQueryIsEmpty() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "bio", op: "IS EMPTY", value: "")]
        )
        #expect(query.contains("\"bio\": \"\""))
    }

    @Test("Filtered query with IS NOT EMPTY operator")
    func filteredQueryIsNotEmpty() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "bio", op: "IS NOT EMPTY", value: "")]
        )
        #expect(query.contains("\"bio\": {\"$ne\": \"\"}"))
    }

    @Test("Filtered query with REGEX operator")
    func filteredQueryRegex() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "name", op: "REGEX", value: "^[A-Z].*")]
        )
        #expect(query.contains("\"$regex\": \"^[A-Z].*\""))
    }

    @Test("Filtered query with sort and offset")
    func filteredQueryWithSortAndOffset() {
        let query = builder.buildFilteredQuery(
            collection: "users",
            queryFilters: [PluginQueryFilter(column: "name", op: "=", value: "Alice")],
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
            from: [PluginQueryFilter(column: "status", op: "IN", value: "active, inactive, pending")]
        )
        #expect(doc.contains("\"$in\""))
        #expect(doc.contains("\"active\""))
        #expect(doc.contains("\"inactive\""))
        #expect(doc.contains("\"pending\""))
    }

    @Test("Filter document with IN operator numeric values")
    func filterDocumentInNumeric() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "age", op: "IN", value: "18, 25, 30")]
        )
        #expect(doc.contains("\"$in\": [18, 25, 30]"))
    }

    @Test("Filter document with NOT IN operator")
    func filterDocumentNotIn() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "status", op: "NOT IN", value: "banned, deleted")]
        )
        #expect(doc.contains("\"$nin\""))
        #expect(doc.contains("\"banned\""))
        #expect(doc.contains("\"deleted\""))
    }

    @Test("Filter document with BETWEEN operator")
    func filterDocumentBetween() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "age", op: "BETWEEN", value: "18, 65")]
        )
        #expect(doc.contains("\"$gte\": 18"))
        #expect(doc.contains("\"$lte\": 65"))
    }

    @Test("Filter document with BETWEEN invalid format matches nothing")
    func filterDocumentBetweenInvalid() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "age", op: "BETWEEN", value: "18")]
        )
        #expect(doc == MongoDBQueryBuilder.impossibleFilter)
    }

    @Test("Filter document with empty filters returns empty object")
    func filterDocumentEmpty() {
        let doc = builder.buildFilterDocument(from: [])
        #expect(doc == "{}")
    }

    @Test("Filter document with unknown operator matches nothing")
    func filterDocumentUnknownOp() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "x", op: "UNKNOWN_OP", value: "y")]
        )
        #expect(doc == MongoDBQueryBuilder.impossibleFilter)
    }

    @Test("A filter whose conditions all drop never widens to the whole collection")
    func filterDocumentNeverFailsOpen() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "x", op: "UNKNOWN_OP", value: "y")]
        )
        #expect(doc != "{}")
    }

    @Test("Filter document with float value")
    func filterDocumentFloat() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "price", op: "=", value: "19.99")]
        )
        #expect(doc.contains("\"price\": 19.99"))
    }

    @Test("Filter document emits JSON-valid scientific numbers")
    func filterDocumentScientificNumber() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "score", op: "=", value: "1.5e-3")]
        )
        let parsed = parseFilter(doc)
        #expect(parsed?["score"] as? Double == 0.0015)
    }

    @Test("Filter document quotes non-JSON numeric spellings")
    func filterDocumentQuotesNonJsonNumericSpellings() {
        let values = [".5", "1.", "+7", "01", "NaN", "Infinity"]
        for value in values {
            let doc = builder.buildFilterDocument(
                from: [PluginQueryFilter(column: "score", op: "=", value: value)]
            )
            let parsed = parseFilter(doc)
            #expect(parsed?["score"] as? String == value)
        }
    }

    @Test("Filter document quotes integers that overflow Int64 to preserve precision")
    func filterDocumentQuotesInt64Overflow() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "code", op: "=", value: "12345678901234567890")]
        )
        let parsed = parseFilter(doc)
        #expect(parsed?["code"] as? String == "12345678901234567890")
    }

    @Test("Filter document quotes exponents that overflow Double instead of emitting Infinity")
    func filterDocumentQuotesOutOfRangeExponent() {
        for value in ["1e400", "-1e400", "1.5e400"] {
            let doc = builder.buildFilterDocument(
                from: [PluginQueryFilter(column: "score", op: "=", value: value)]
            )
            let parsed = parseFilter(doc)
            #expect(parsed?["score"] as? String == value)
        }
    }

    @Test("Filter document emits the largest Int64 integer unquoted")
    func filterDocumentEmitsMaxInt64() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "code", op: "=", value: "9223372036854775807")]
        )
        #expect(doc.contains("\"code\": 9223372036854775807"))
    }

    @Test("Filter document with null literal")
    func filterDocumentNullLiteral() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "field", op: "=", value: "null")]
        )
        #expect(doc.contains("\"field\": null"))
    }

    // MARK: - Combined Query
    // TODO: Re-enable when buildCombinedQuery API is restored
    #if false
    @Test("Combined query wraps filter and search in $and")
    func combinedQuery() {
        let query = builder.buildCombinedQuery(
            collection: "users",
            filters: [PluginQueryFilter(column: "age", op: ">", value: "25")],
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
            filters: [PluginQueryFilter(column: "age", op: ">", value: "18")],
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
    #endif

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
        #expect(query.hasPrefix("db.getCollection(\"my.data\")"))
        #expect(query.contains(".countDocuments({})"))
    }

    // MARK: - Export Query

    @Test("Export query streams the whole collection")
    func exportQueryHasNoLimit() {
        let query = builder.buildExportQuery(collection: "users")
        #expect(query == "db.users.find({})")
    }

    @Test("Export query reaches a dotted collection through getCollection")
    func exportQueryDottedCollection() {
        let query = builder.buildExportQuery(collection: "logs.2024.06")
        #expect(query == "db.getCollection(\"logs.2024.06\").find({})")
    }

    @Test("Export query escapes quotes and backslashes in the collection name")
    func exportQueryEscapesCollectionName() {
        let query = builder.buildExportQuery(collection: "say\"hi\\bye")
        #expect(query == "db.getCollection(\"say\\\"hi\\\\bye\").find({})")
    }

    @Test("Export query parses back to a find on the same collection")
    func exportQueryRoundTripsThroughTheParser() throws {
        for collection in ["users", "logs.2024.06", "stats", "2024_orders", "say\"hi"] {
            let operation = try MongoShellParser.parse(builder.buildExportQuery(collection: collection))
            if case .find(let parsed, let filter, let options) = operation {
                #expect(parsed == collection)
                #expect(filter == "{}")
                #expect(options.limit == nil)
            } else {
                Issue.record("Expected .find operation for \(collection)")
            }
        }
    }

    // MARK: - ObjectId Matching

    @Test("Equals on an ObjectId value matches both the ObjectId and the string form")
    func equalsObjectIdDualMatch() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "_id", op: "=", value: "66c0fa26dfcb27034e646356")]
        )
        let parsed = parseFilter(doc)
        let branches = parsed?["$or"] as? [[String: Any]]
        #expect(branches?.count == 2)
        let oid = (branches?.first?["_id"] as? [String: Any])?["$oid"] as? String
        #expect(oid == "66c0fa26dfcb27034e646356")
        #expect(branches?.last?["_id"] as? String == "66c0fa26dfcb27034e646356")
    }

    @Test("Equals on a non-ObjectId string stays a plain string match")
    func equalsNonObjectIdString() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "_id", op: "=", value: "user-123")]
        )
        #expect(!doc.contains("$or"))
        #expect(!doc.contains("$oid"))
        #expect(doc.contains("\"_id\": \"user-123\""))
    }

    @Test("Equals on a 23-character hex value is not treated as an ObjectId")
    func equalsShortHexNotObjectId() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "_id", op: "=", value: "66c0fa26dfcb27034e64635")]
        )
        #expect(!doc.contains("$oid"))
    }

    @Test("Equals on a 24-character non-hex value is not treated as an ObjectId")
    func equalsNonHexNotObjectId() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "_id", op: "=", value: "zzc0fa26dfcb27034e646356")]
        )
        #expect(!doc.contains("$oid"))
    }

    @Test("ObjectId matching applies to non-_id reference fields too")
    func equalsObjectIdReferenceField() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "userId", op: "=", value: "66c0fa26dfcb27034e646356")]
        )
        let branches = parseFilter(doc)?["$or"] as? [[String: Any]]
        let oid = (branches?.first?["userId"] as? [String: Any])?["$oid"] as? String
        #expect(oid == "66c0fa26dfcb27034e646356")
    }

    @Test("Not-equals on an ObjectId value excludes both the ObjectId and the string form")
    func notEqualsObjectIdDualMatch() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "_id", op: "!=", value: "66c0fa26dfcb27034e646356")]
        )
        let nin = (parseFilter(doc)?["_id"] as? [String: Any])?["$nin"] as? [Any]
        #expect(nin?.count == 2)
        let oid = (nin?.first as? [String: Any])?["$oid"] as? String
        #expect(oid == "66c0fa26dfcb27034e646356")
        #expect(nin?.last as? String == "66c0fa26dfcb27034e646356")
    }

    @Test("IN expands an ObjectId item to both forms and leaves plain items alone")
    func inExpandsObjectIdItems() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "_id", op: "IN", value: "66c0fa26dfcb27034e646356, plain-id")]
        )
        let inArray = (parseFilter(doc)?["_id"] as? [String: Any])?["$in"] as? [Any]
        #expect(inArray?.count == 3)
        let oid = (inArray?.first as? [String: Any])?["$oid"] as? String
        #expect(oid == "66c0fa26dfcb27034e646356")
        let strings = inArray?.compactMap { $0 as? String }
        #expect(strings?.contains("66c0fa26dfcb27034e646356") == true)
        #expect(strings?.contains("plain-id") == true)
    }

    @Test("NOT IN expands an ObjectId item to both forms")
    func notInExpandsObjectIdItems() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "_id", op: "NOT IN", value: "66c0fa26dfcb27034e646356, plain-id")]
        )
        let ninArray = (parseFilter(doc)?["_id"] as? [String: Any])?["$nin"] as? [Any]
        #expect(ninArray?.count == 3)
        let oid = (ninArray?.first as? [String: Any])?["$oid"] as? String
        #expect(oid == "66c0fa26dfcb27034e646356")
        let strings = ninArray?.compactMap { $0 as? String }
        #expect(strings?.contains("plain-id") == true)
    }

    @Test("An ObjectId equals combined with another filter stays valid JSON under $and")
    func objectIdEqualsCombinedWithAndFilter() {
        let doc = builder.buildFilterDocument(
            from: [
                PluginQueryFilter(column: "_id", op: "=", value: "66c0fa26dfcb27034e646356"),
                PluginQueryFilter(column: "shop", op: "=", value: "acme")
            ],
            logicMode: "and"
        )
        let branches = parseFilter(doc)?["$and"] as? [[String: Any]]
        #expect(branches?.count == 2)
        let or = branches?.first?["$or"] as? [[String: Any]]
        let oid = (or?.first?["_id"] as? [String: Any])?["$oid"] as? String
        #expect(oid == "66c0fa26dfcb27034e646356")
        #expect(branches?.last?["shop"] as? String == "acme")
    }

    // MARK: - Security (NoSQL injection)

    private func parseFilter(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test("REGEX value cannot break out of the regex string to inject operators")
    func regexInjectionContained() {
        let payload = ".*\"}, \"$where\": \"function(){return true}\", \"_\":{\"a\":\""
        let doc = parseFilter(
            builder.buildFilterDocument(from: [
                PluginQueryFilter(column: "name", op: "REGEX", value: payload, isCaseSensitive: false)
            ])
        )
        #expect(doc != nil)
        #expect(doc.map { Array($0.keys) } == ["name"])
        let inner = doc?["name"] as? [String: Any]
        #expect(inner.map { Array($0.keys).sorted() } == ["$options", "$regex"])
        #expect(inner?["$regex"] as? String == payload)
        #expect(inner?["$options"] as? String == "i")
    }

    @Test("Regex injection payload stays contained when matching case")
    func regexInjectionContainedMatchingCase() {
        let payload = ".*\"}, \"$where\": \"function(){return true}\", \"_\":{\"a\":\""
        let doc = parseFilter(
            builder.buildFilterDocument(from: [PluginQueryFilter(column: "name", op: "REGEX", value: payload)])
        )
        #expect(doc.map { Array($0.keys) } == ["name"])
        let inner = doc?["name"] as? [String: Any]
        #expect(inner.map { Array($0.keys) } == ["$regex"])
        #expect(inner?["$regex"] as? String == payload)
    }

    @Test("CONTAINS value cannot break out of the regex string to inject operators")
    func containsInjectionContained() {
        let payload = "\"}, \"$where\": \"return true"
        let doc = parseFilter(
            builder.buildFilterDocument(from: [PluginQueryFilter(column: "name", op: "CONTAINS", value: payload)])
        )
        #expect(doc != nil)
        #expect(doc.map { Array($0.keys) } == ["name"])
        let regex = (doc?["name"] as? [String: Any])?["$regex"] as? String
        #expect(regex?.contains("$where") == true)
    }

    @Test("NOT CONTAINS value cannot break out of the nested regex string")
    func notContainsInjectionContained() {
        let payload = "\"}}, \"$where\": \"1==1"
        let doc = parseFilter(
            builder.buildFilterDocument(from: [PluginQueryFilter(column: "name", op: "NOT CONTAINS", value: payload)])
        )
        #expect(doc != nil)
        #expect(doc.map { Array($0.keys) } == ["name"])
        let not = (doc?["name"] as? [String: Any])?["$not"] as? [String: Any]
        #expect((not?["$regex"] as? String)?.contains("$where") == true)
    }

    @Test("STARTS WITH escapes embedded double quotes as data")
    func startsWithEscapesQuote() {
        let doc = parseFilter(
            builder.buildFilterDocument(from: [PluginQueryFilter(column: "name", op: "STARTS WITH", value: "Al\"ce")])
        )
        #expect(doc != nil)
        let inner = doc?["name"] as? [String: Any]
        #expect(inner?["$regex"] as? String == "^Al\"ce")
    }

    @Test("ENDS WITH escapes embedded double quotes as data")
    func endsWithEscapesQuote() {
        let doc = parseFilter(
            builder.buildFilterDocument(from: [PluginQueryFilter(column: "name", op: "ENDS WITH", value: "ce\"Al")])
        )
        #expect(doc != nil)
        let inner = doc?["name"] as? [String: Any]
        #expect(inner?["$regex"] as? String == "ce\"Al$")
    }

    @Test("CONTAINS escapes a backslash to a literal-backslash regex")
    func containsEscapesBackslash() {
        let doc = parseFilter(
            builder.buildFilterDocument(from: [PluginQueryFilter(column: "path", op: "CONTAINS", value: "\\")])
        )
        #expect(doc != nil)
        let inner = doc?["path"] as? [String: Any]
        #expect(inner?["$regex"] as? String == "\\\\")
    }

    @Test("REGEX preserves regex metacharacters literally")
    func regexPreservesMetacharacters() {
        let value = "^[A-Z].*\\d$"
        let doc = parseFilter(
            builder.buildFilterDocument(from: [PluginQueryFilter(column: "name", op: "REGEX", value: value)])
        )
        #expect(doc != nil)
        let inner = doc?["name"] as? [String: Any]
        #expect(inner?["$regex"] as? String == value)
    }

    @Test("REGEX keeps an embedded double quote as data")
    func regexEscapesQuote() {
        let doc = parseFilter(
            builder.buildFilterDocument(from: [PluginQueryFilter(column: "name", op: "REGEX", value: "a\"b")])
        )
        #expect(doc != nil)
        let inner = doc?["name"] as? [String: Any]
        #expect(inner?["$regex"] as? String == "a\"b")
    }

    @Test("CONTAINS treats regex metacharacters as literals")
    func containsTreatsMetacharactersLiterally() {
        let doc = parseFilter(
            builder.buildFilterDocument(from: [PluginQueryFilter(column: "name", op: "CONTAINS", value: "a.b")])
        )
        #expect(doc != nil)
        let inner = doc?["name"] as? [String: Any]
        #expect(inner?["$regex"] as? String == "a\\.b")
    }

    // MARK: - Binary UUID filters

    private static let uuid = "8cd003eb-4a25-4324-9332-88fce2da0d1a"
    private static let javaBase64 = "JEMlSusD0IwaDdri/Igykw=="

    @Test("Equality on a UUID wrapper filters on BSON binary, not on the wrapper text")
    func equalityUsesBinary() {
        let doc = builder.buildFilterDocument(
            from: [
                PluginQueryFilter(
                    column: "ref", op: "=", value: "LegacyJavaUUID(\"\(Self.uuid)\")"
                )
            ]
        )
        #expect(doc.contains("\"$binary\""))
        #expect(doc.contains("\"subType\": \"03\""))
        #expect(doc.contains(Self.javaBase64))
    }

    /// A binary field has no case, so a case-insensitive regex would match nothing.
    @Test("A case-insensitive equality on a UUID wrapper still matches exactly")
    func caseInsensitiveEqualityStaysExact() {
        let doc = builder.buildFilterDocument(
            from: [
                PluginQueryFilter(
                    column: "ref",
                    op: "=",
                    value: "LegacyJavaUUID(\"\(Self.uuid)\")",
                    isCaseSensitive: false
                )
            ]
        )
        #expect(doc.contains("\"$binary\""))
        #expect(!doc.contains("$regex"))
    }

    @Test("Inequality on a UUID wrapper uses $ne with binary")
    func inequalityUsesBinary() {
        let doc = builder.buildFilterDocument(
            from: [
                PluginQueryFilter(
                    column: "ref", op: "!=", value: "UUID(\"\(Self.uuid)\")"
                )
            ]
        )
        #expect(doc.contains("\"$ne\""))
        #expect(doc.contains("\"subType\": \"04\""))
    }

    @Test("IN over UUID wrappers uses binary values")
    func inListUsesBinary() {
        let doc = builder.buildFilterDocument(
            from: [
                PluginQueryFilter(
                    column: "ref",
                    op: "IN",
                    value: "UUID(\"\(Self.uuid)\"), LegacyJavaUUID(\"\(Self.uuid)\")"
                )
            ]
        )
        #expect(doc.contains("\"$in\""))
        #expect(doc.contains("\"subType\": \"04\""))
    }

    @Test("A plain string value is unaffected by UUID handling")
    func plainStringUnaffected() {
        let doc = builder.buildFilterDocument(
            from: [PluginQueryFilter(column: "name", op: "=", value: "UUID-ish")]
        )
        #expect(!doc.contains("$binary"))
    }

    // MARK: - Collection accessor

    @Test("A collection named after a db method is reached through getCollection")
    func shadowedCollectionNamesUseGetCollection() {
        for name in ["stats", "version", "toString", "constructor", "valueOf", "getName", "__proto__"] {
            let query = builder.buildBaseQuery(collection: name)
            #expect(query == "db.getCollection(\"\(name)\").find({}).limit(200)", "collection \(name)")
        }
    }

    @Test("A shadowed collection name parses back to a find on that collection")
    func shadowedCollectionNameRoundTripsThroughTheParser() throws {
        let operation = try MongoShellParser.parse(builder.buildBaseQuery(collection: "stats"))
        guard case .find(let collection, _, _) = operation else {
            Issue.record("Expected .find operation")
            return
        }
        #expect(collection == "stats")
    }

    @Test("Every method the shell puts on db is a name the accessor refuses to spell as db.<name>")
    func accessorCoversEveryDatabaseMethodOfTheShell() throws {
        let regex = try NSRegularExpression(pattern: #"DB\.prototype\.([A-Za-z_][A-Za-z0-9_]*)\s*="#)
        let source = MongoScriptPrelude.source
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let members = matches.compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
        #expect(members.count > 10)
        for member in members {
            #expect(MongoCollectionAccessor.isShadowedByDatabaseMember(member), "db.\(member) is a method")
        }
    }

    // MARK: - Raw filter normalization

    private static let normalizer = MongoDBRawFilterNormalizer()

    private var normalizingBuilder: MongoDBQueryBuilder {
        MongoDBQueryBuilder(rawFilterNormalizer: { Self.normalizer.normalize($0) })
    }

    @Test("A raw filter in shell syntax is rewritten to Extended JSON for find and count alike")
    func rawFilterInShellSyntaxBecomesExtendedJSON() throws {
        let raw = PluginQueryFilter(
            column: MongoDBQueryBuilder.rawFilterColumn, op: "RAW",
            value: "{status: 'active', _id: ObjectId(\"507f1f77bcf86cd799439011\"), n: 3}"
        )
        let doc = normalizingBuilder.buildFilterDocument(from: [raw])
        let expected = "{\"$and\": [{\"status\":\"active\","
            + "\"_id\":{\"$oid\":\"507f1f77bcf86cd799439011\"},\"n\":{\"$numberInt\":\"3\"}}]}"
        #expect(doc == expected)
        let parsed = try JSONSerialization.jsonObject(with: Data(doc.utf8)) as? [String: Any]
        #expect((parsed?["$and"] as? [[String: Any]])?.count == 1)
        let find = normalizingBuilder.buildFilteredQuery(collection: "users", queryFilters: [raw])
        #expect(find == "db.users.find(\(expected)).limit(200)")
    }

    @Test("A raw filter the shell cannot evaluate is kept as typed")
    func rawFilterThatFailsToEvaluateIsKeptVerbatim() {
        let raw = PluginQueryFilter(
            column: MongoDBQueryBuilder.rawFilterColumn, op: "RAW", value: "{status: }"
        )
        let doc = normalizingBuilder.buildFilterDocument(from: [raw])
        #expect(doc == "{\"$and\": [{status: }]}")
    }

    @Test("The normalizer serializes dates and regex literals the way the shell does")
    func normalizerSerializesShellValues() {
        let normalized = Self.normalizer.normalize("{at: ISODate(\"2024-01-02T00:00:00Z\"), name: /^bo/i}")
        let expected = "{\"at\":{\"$date\":{\"$numberLong\":\"1704153600000\"}},"
            + "\"name\":{\"$regularExpression\":{\"pattern\":\"^bo\",\"options\":\"i\"}}}"
        #expect(normalized == expected)
        #expect(Self.normalizer.normalize("{}") == "{}")
        #expect(Self.normalizer.normalize("{_id: ObjectId()}") == nil)
    }
}
