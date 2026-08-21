//
//  MongoDBNestedFilterTests.swift
//  TableProTests
//
//  Nested field paths, $elemMatch grouping and BSON-typed filter values
//  (compiled via symlink from MongoDBDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MongoDB Nested Field Filtering")
struct MongoDBNestedFilterTests {
    private func filter(
        _ column: String,
        _ op: String,
        _ value: String,
        secondValue: String? = nil,
        elementScope: String? = nil,
        isCaseSensitive: Bool = true
    ) -> PluginQueryFilter {
        PluginQueryFilter(
            column: column, op: op, value: value, isCaseSensitive: isCaseSensitive,
            secondValue: secondValue, elementScope: elementScope
        )
    }

    // MARK: - Dot Notation

    @Test("A dotted path reaches the query verbatim, with the dot intact")
    func dottedPathIsNotEscaped() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("customer.country", "=", "US")]
        )
        #expect(doc == "{\"customer.country\": \"US\"}")
    }

    @Test("A dotted path works with a comparison operator")
    func dottedPathComparison() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("customer.age", ">=", "18")]
        )
        #expect(doc == "{\"customer.age\": {\"$gte\": 18}}")
    }

    @Test("A single array-path condition stays dot notation, never $elemMatch")
    func singleArrayConditionIsNotWrapped() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("items.sku", "=", "A100")]
        )
        #expect(doc == "{\"items.sku\": \"A100\"}")
        #expect(!doc.contains("$elemMatch"))
    }

    @Test("Two array-path conditions without a scope stay independent")
    func twoUnscopedArrayConditionsStayIndependent() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("items.price", ">", "500"), filter("items.name", "=", "Laptop")]
        )
        #expect(!doc.contains("$elemMatch"))
        #expect(doc.contains("\"items.price\": {\"$gt\": 500}"))
        #expect(doc.contains("\"items.name\": \"Laptop\""))
    }

    // MARK: - $elemMatch

    @Test("Two conditions sharing a scope collapse into one $elemMatch")
    func scopedConditionsCollapse() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [
                filter("items.price", ">", "500", elementScope: "items"),
                filter("items.name", "=", "Laptop", elementScope: "items"),
            ]
        )
        #expect(doc == "{\"items\": {\"$elemMatch\": {\"price\": {\"$gt\": 500}, \"name\": \"Laptop\"}}}")
    }

    @Test("A single scoped condition is still emitted as $elemMatch, never silently downgraded")
    func singleScopedConditionKeepsElemMatch() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("items.sku", "=", "A100", elementScope: "items")]
        )
        #expect(doc == "{\"items\": {\"$elemMatch\": {\"sku\": \"A100\"}}}")
    }

    @Test("Two different array prefixes produce two separate $elemMatch clauses")
    func separatePrefixesDoNotMerge() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [
                filter("items.sku", "=", "A100", elementScope: "items"),
                filter("shipments.carrier", "=", "DHL", elementScope: "shipments"),
            ]
        )
        #expect(doc.contains("\"items\": {\"$elemMatch\": {\"sku\": \"A100\"}}"))
        #expect(doc.contains("\"shipments\": {\"$elemMatch\": {\"carrier\": \"DHL\"}}"))
        #expect(doc.hasPrefix("{\"$and\": ["))
    }

    @Test("A scoped condition mixes with an unscoped one under the logic operator")
    func scopedAndUnscopedCombine() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [
                filter("customer.country", "=", "US"),
                filter("items.price", ">", "500", elementScope: "items"),
            ],
            logicMode: "and"
        )
        #expect(doc.contains("\"customer.country\": \"US\""))
        #expect(doc.contains("\"items\": {\"$elemMatch\": {\"price\": {\"$gt\": 500}}}"))
    }

    @Test("Scoped conditions honour the OR logic mode alongside other rows")
    func scopedRespectsOrLogicMode() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [
                filter("customer.country", "=", "US"),
                filter("items.price", ">", "500", elementScope: "items"),
            ],
            logicMode: "or"
        )
        #expect(doc.hasPrefix("{\"$or\": ["))
    }

    @Test("A deeper path under a scope keeps its remaining segments inside $elemMatch")
    func deeperPathKeepsRemainder() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("orders.customer.country", "=", "US", elementScope: "orders")]
        )
        #expect(doc == "{\"orders\": {\"$elemMatch\": {\"customer.country\": \"US\"}}}")
    }

    @Test("Two scoped conditions claiming the same key fall back to $and inside $elemMatch")
    func collidingKeysInsideScopeUseAnd() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [
                filter("items.price", ">", "10", elementScope: "items"),
                filter("items.price", "<", "90", elementScope: "items"),
            ]
        )
        #expect(doc.contains("$elemMatch"))
        #expect(doc.contains("\"$and\""))
        #expect(doc.contains("{\"$gt\": 10}"))
        #expect(doc.contains("{\"$lt\": 90}"))
    }

    @Test("A scope whose conditions all drop does not emit an empty $elemMatch")
    func emptyScopeIsDropped() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("items.sku", "UNKNOWN_OP", "x", elementScope: "items")]
        )
        #expect(!doc.contains("$elemMatch"))
        #expect(doc == MongoDBQueryBuilder.impossibleFilter)
    }

    // MARK: - Raw Filter Document

    @Test("A raw filter row is used as the filter document, not as a field named __RAW__")
    func rawFilterIsUsedAsDocument() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter(MongoDBQueryBuilder.rawFilterColumn, "=", "{\"customer.country\": \"US\"}")]
        )
        #expect(!doc.contains("__RAW__"))
        #expect(doc.contains("{\"customer.country\": \"US\"}"))
    }

    @Test("A raw filter row that is not a document is dropped rather than matching everything")
    func rawFilterRejectsNonDocument() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter(MongoDBQueryBuilder.rawFilterColumn, "=", "customer.country = 'US'")]
        )
        #expect(!doc.contains("__RAW__"))
        #expect(doc == MongoDBQueryBuilder.impossibleFilter)
    }

    @Test("A raw filter of {} keeps MongoDB's own meaning of match everything")
    func rawFilterEmptyDocumentMatchesAll() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter(MongoDBQueryBuilder.rawFilterColumn, "=", "{}")]
        )
        #expect(doc == "{\"$and\": [{}]}")
        #expect(doc != MongoDBQueryBuilder.impossibleFilter)
    }

    @Test("A raw filter combines with a column row under the logic operator")
    func rawFilterCombinesWithColumnRow() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [
                filter(MongoDBQueryBuilder.rawFilterColumn, "=", "{\"items.sku\": \"A100\"}"),
                filter("customer.country", "=", "US"),
            ]
        )
        #expect(doc.hasPrefix("{\"$and\": ["))
        #expect(doc.contains("{\"items.sku\": \"A100\"}"))
        #expect(doc.contains("\"customer.country\": \"US\""))
    }

    // MARK: - BETWEEN

    @Test("BETWEEN reads secondValue, so a bound holding a comma survives")
    func betweenUsesSecondValue() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("name", "BETWEEN", "Smith, John", secondValue: "Zed")]
        )
        #expect(doc == "{\"name\": {\"$gte\": \"Smith, John\", \"$lte\": \"Zed\"}}")
    }

    @Test("BETWEEN still parses the joined form when no secondValue is supplied")
    func betweenFallsBackToJoinedValue() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("age", "BETWEEN", "18, 65")]
        )
        #expect(doc == "{\"age\": {\"$gte\": 18, \"$lte\": 65}}")
    }

    @Test("BETWEEN with a blank bound matches nothing rather than widening")
    func betweenBlankBound() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("age", "BETWEEN", "18", secondValue: "  ")]
        )
        #expect(doc == MongoDBQueryBuilder.impossibleFilter)
    }

    // MARK: - BSON Type Coercion

    @Test("A Date column compares against an Extended JSON date, not a string")
    func dateColumnIsCoerced() {
        let builder = MongoDBQueryBuilder(columnKinds: ["createdAt": .date])
        let doc = builder.buildFilterDocument(
            from: [filter("createdAt", ">=", "2024-01-01T00:00:00Z")]
        )
        #expect(doc == "{\"createdAt\": {\"$gte\": {\"$date\": {\"$numberLong\": \"1704067200000\"}}}}")
    }

    @Test("A nested Date path is coerced the same way as a top-level one")
    func nestedDateIsCoerced() {
        let builder = MongoDBQueryBuilder(columnKinds: ["customer.registeredAt": .date])
        let doc = builder.buildFilterDocument(
            from: [filter("customer.registeredAt", ">=", "2024-01-01")]
        )
        #expect(doc.contains("\"$date\""))
        #expect(doc.contains("\"customer.registeredAt\""))
    }

    @Test("A Date inside $elemMatch is coerced from the full path's kind")
    func dateInsideElemMatchIsCoerced() {
        let builder = MongoDBQueryBuilder(columnKinds: ["items.shippedAt": .date])
        let doc = builder.buildFilterDocument(
            from: [filter("items.shippedAt", ">=", "2024-01-01", elementScope: "items")]
        )
        #expect(doc.contains("\"items\": {\"$elemMatch\": {\"shippedAt\": {\"$gte\": {\"$date\""))
    }

    @Test("An unparseable date falls back to the literal rather than emitting a bad wrapper")
    func unparseableDateFallsBack() {
        let builder = MongoDBQueryBuilder(columnKinds: ["createdAt": .date])
        let doc = builder.buildFilterDocument(
            from: [filter("createdAt", ">=", "last tuesday")]
        )
        #expect(doc == "{\"createdAt\": {\"$gte\": \"last tuesday\"}}")
    }

    @Test("An ObjectId column compares as $oid on a range operator")
    func objectIdRangeIsCoerced() {
        let builder = MongoDBQueryBuilder(columnKinds: ["_id": .objectId])
        let doc = builder.buildFilterDocument(
            from: [filter("_id", ">", "507f1f77bcf86cd799439011")]
        )
        #expect(doc == "{\"_id\": {\"$gt\": {\"$oid\": \"507f1f77bcf86cd799439011\"}}}")
    }

    @Test("A Decimal128 column compares as $numberDecimal")
    func decimalIsCoerced() {
        let builder = MongoDBQueryBuilder(columnKinds: ["price": .decimal128])
        let doc = builder.buildFilterDocument(from: [filter("price", ">=", "19.99")])
        #expect(doc == "{\"price\": {\"$gte\": {\"$numberDecimal\": \"19.99\"}}}")
    }

    @Test("A 24-hex value on a known string column is not guessed as an ObjectId")
    func hexStringColumnIsNotGuessed() {
        let builder = MongoDBQueryBuilder(columnKinds: ["token": .string])
        let doc = builder.buildFilterDocument(
            from: [filter("token", "=", "507f1f77bcf86cd799439011")]
        )
        #expect(doc == "{\"token\": \"507f1f77bcf86cd799439011\"}")
    }

    @Test("A 24-hex value on an unsampled column keeps the both-ways match")
    func hexStringUnknownColumnKeepsAlternatives() {
        let doc = MongoDBQueryBuilder().buildFilterDocument(
            from: [filter("ref", "=", "507f1f77bcf86cd799439011")]
        )
        #expect(doc.contains("$or"))
        #expect(doc.contains("$oid"))
    }

    // MARK: - Ignore Case Against Non-String Kinds

    @Test("Ignore case on a numeric column does not become a regex that matches nothing")
    func ignoreCaseOnNumberStaysExact() {
        let builder = MongoDBQueryBuilder(columnKinds: ["age": .int32])
        let doc = builder.buildFilterDocument(
            from: [filter("age", "=", "28", isCaseSensitive: false)]
        )
        #expect(doc == "{\"age\": 28}")
        #expect(!doc.contains("$regex"))
    }

    @Test("Ignore case on a numeric column does not invert a not-equals into match-all")
    func ignoreCaseOnNumberNotEquals() {
        let builder = MongoDBQueryBuilder(columnKinds: ["age": .int32])
        let doc = builder.buildFilterDocument(
            from: [filter("age", "!=", "28", isCaseSensitive: false)]
        )
        #expect(doc == "{\"age\": {\"$ne\": 28}}")
        #expect(!doc.contains("$not"))
    }

    @Test("Ignore case on a string column still uses an anchored regex")
    func ignoreCaseOnStringUsesRegex() {
        let builder = MongoDBQueryBuilder(columnKinds: ["name": .string])
        let doc = builder.buildFilterDocument(
            from: [filter("name", "=", "alice", isCaseSensitive: false)]
        )
        #expect(doc.contains("\"$regex\": \"^alice$\""))
        #expect(doc.contains("\"$options\": \"i\""))
    }

    // MARK: - Relative Paths

    @Test("A path is re-keyed relative to its scope")
    func relativePathStripsPrefix() {
        #expect(MongoDBQueryBuilder.relativePath("items.sku", under: "items") == "sku")
        #expect(MongoDBQueryBuilder.relativePath("orders.items.sku", under: "orders") == "items.sku")
    }

    @Test("A path that does not sit under the scope is left alone")
    func relativePathLeavesUnrelatedPath() {
        #expect(MongoDBQueryBuilder.relativePath("customer.name", under: "items") == "customer.name")
        #expect(MongoDBQueryBuilder.relativePath("itemsTotal", under: "items") == "itemsTotal")
    }
}
