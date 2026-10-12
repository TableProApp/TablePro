import Foundation
@testable import TableProFirebaseCore
import Testing

@Suite("Firestore cells")
struct FirestoreCellTests {
    @Test("Values display as text the grid can show")
    func display() {
        #expect(FirestoreCell.display(.null) == .null)
        #expect(FirestoreCell.display(.boolean(true)) == .text("true"))
        #expect(FirestoreCell.display(.double(2)) == .text("2.0"))
        #expect(FirestoreCell.display(.geoPoint(latitude: 45.5, longitude: 9.0)) == .text("45.5, 9.0"))
        #expect(FirestoreCell.display(.map(["a": .integer(1)])) == .text(#"{"a":1}"#))
        #expect(FirestoreCell.display(.bytes(Data([1]))) == .bytes(Data([1])))
    }

    @Test("An edit keeps the type the field had")
    func typedEdits() throws {
        #expect(try FirestoreCell.value(text: "42", typeName: "string") == .string("42"))
        #expect(try FirestoreCell.value(text: " 42 ", typeName: "integer") == .integer(42))
        #expect(try FirestoreCell.value(text: "4.5", typeName: "double") == .double(4.5))
        #expect(try FirestoreCell.value(text: "FALSE", typeName: "boolean") == .boolean(false))
        #expect(try FirestoreCell.value(text: "2026-10-12T08:00:00Z", typeName: "timestamp") == .timestamp("2026-10-12T08:00:00Z"))
        #expect(try FirestoreCell.value(text: "/users/bob", typeName: "reference") == .reference("users/bob"))
        #expect(try FirestoreCell.value(text: "45.5, 9", typeName: "geopoint") == .geoPoint(latitude: 45.5, longitude: 9))
        #expect(try FirestoreCell.value(text: #"{"a": [1]}"#, typeName: "map") == .map(["a": .array([.integer(1)])]))
    }

    @Test("An edit that does not fit the type is refused with an example")
    func mismatch() {
        #expect(throws: FirebaseError.self) { try FirestoreCell.value(text: "4.5", typeName: "integer") }
        #expect(throws: FirebaseError.self) { try FirestoreCell.value(text: "soon", typeName: "timestamp") }
        #expect(throws: FirebaseError.self) { try FirestoreCell.value(text: "users", typeName: "reference") }
        #expect(throws: FirebaseError.self) { try FirestoreCell.value(text: "1", typeName: "geopoint") }
    }

    @Test("A new field infers JSON literals and keeps other text as a string")
    func inferred() {
        #expect(FirestoreCell.inferred("12") == .integer(12))
        #expect(FirestoreCell.inferred("true") == .boolean(true))
        #expect(FirestoreCell.inferred("[1]") == .array([.integer(1)]))
        #expect(FirestoreCell.inferred("hello") == .string("hello"))
        #expect(FirestoreCell.inferred("\"quoted\"") == .string("\"quoted\""))
    }

    @Test("A column's type is what most of its cells hold")
    func dominantType() {
        #expect(FirestoreCell.dominantType([.string("a"), .null, .string("b"), .integer(1)]) == "string")
        #expect(FirestoreCell.dominantType([nil, .null]) == "null")
        #expect(FirestoreCell.dominantType([nil]) == "string")
    }

    @Test("Rows put __name__ first and mark missing fields absent")
    func rows() throws {
        let target = try FirestoreCollectionTarget(table: "users")
        let rows = FirestoreRowSet(documents: [
            FirestoreDocument(path: "users/alice", fields: ["age": .integer(30), "name": .string("Alice")]),
            FirestoreDocument(path: "users/bob", fields: ["name": .string("Bob")])
        ], target: target)
        #expect(rows.columns == ["__name__", "age", "name"])
        #expect(rows.columnTypes == ["string", "integer", "string"])
        #expect(rows.rows[0] == [.text("alice"), .text("30"), .text("Alice")])
        #expect(rows.absentCells == [1: [1]])
        #expect(rows.locators == ["users/alice", "users/bob"])
        #expect(rows.cellTypes["users/bob"] == ["name": "string"])
    }
}

@Suite("Firestore query builder")
struct FirestoreQueryBuilderTests {
    private func filterJSON(_ filter: FirebaseFilterSpec, types: [String: String] = [:], table: String = "users") throws -> String {
        let spec = FirebaseBrowseSpec(table: table, filters: [filter], limit: 0, offset: 0)
        let query = try FirestoreQueryBuilder.structuredQuery(
            spec: spec, target: try FirestoreCollectionTarget(table: table),
            documentRoot: testDocumentRoot, typeOf: { types[$0] }
        )
        return query["structuredQuery"]?["where"]?.text() ?? ""
    }

    @Test("A page carries from, order, offset and limit")
    func page() throws {
        let spec = FirebaseBrowseSpec(
            table: "users/alice/orders", sorts: [FirebaseSortSpec(column: "total", ascending: false)], limit: 50, offset: 100
        )
        let target = try FirestoreCollectionTarget(table: spec.table)
        #expect(target.parentPath == "users/alice")
        let query = try FirestoreQueryBuilder.structuredQuery(spec: spec, target: target, documentRoot: testDocumentRoot, typeOf: noTypes)
        let expected = #"{"structuredQuery":{"from":[{"allDescendants":false,"collectionId":"orders"}],"limit":50,"offset":100,"#
            + #""orderBy":[{"direction":"DESCENDING","field":{"fieldPath":"total"}}]}}"#
        #expect(query.text() == expected)
    }

    @Test("Filter values are typed by the field's type")
    func typedValues() throws {
        #expect(try filterJSON(FirebaseFilterSpec(column: "age", op: ">=", value: "30"), types: ["age": "integer"])
            == #"{"fieldFilter":{"field":{"fieldPath":"age"},"op":"GREATER_THAN_OR_EQUAL","value":{"integerValue":"30"}}}"#)
        #expect(try filterJSON(FirebaseFilterSpec(column: "zip", op: "=", value: "02134"), types: ["zip": "string"])
            == #"{"fieldFilter":{"field":{"fieldPath":"zip"},"op":"EQUAL","value":{"stringValue":"02134"}}}"#)
        #expect(try filterJSON(FirebaseFilterSpec(column: "score", op: "!=", value: "7"))
            == #"{"fieldFilter":{"field":{"fieldPath":"score"},"op":"NOT_EQUAL","value":{"integerValue":"7"}}}"#)
    }

    @Test("__name__ compares document references")
    func nameFilter() throws {
        #expect(try filterJSON(FirebaseFilterSpec(column: "__name__", op: "=", value: "alice"))
            == #"{"fieldFilter":{"field":{"fieldPath":"__name__"},"op":"EQUAL","value":{"referenceValue":"projects/demo/databases/(default)/documents/users/alice"}}}"#)
        #expect(try filterJSON(FirebaseFilterSpec(column: "__name__", op: "=", value: "users/a/orders/1"), table: "*/orders")
            .contains("documents/users/a/orders/1"))
    }

    @Test("Range, list and null operators map to Firestore operators")
    func operators() throws {
        let between = try filterJSON(FirebaseFilterSpec(column: "age", op: "BETWEEN", value: "1", secondValue: "9"), types: ["age": "integer"])
        #expect(between.contains("GREATER_THAN_OR_EQUAL") && between.contains("LESS_THAN_OR_EQUAL"))
        let prefix = try filterJSON(FirebaseFilterSpec(column: "name", op: "STARTS WITH", value: "Al"))
        #expect(prefix.contains("\"Al\u{F8FF}\""))
        let list = try filterJSON(FirebaseFilterSpec(column: "tier", op: "NOT IN", value: "gold, silver"), types: ["tier": "string"])
        #expect(list.contains(#""op":"NOT_IN""#) && list.contains(#"{"stringValue":"silver"}"#))
        #expect(try filterJSON(FirebaseFilterSpec(column: "x", op: "IS NULL", value: "")).contains("IS_NULL"))
        #expect(try filterJSON(FirebaseFilterSpec(column: "tags", op: "CONTAINS", value: "vip"), types: ["tags": "array"])
            .contains("ARRAY_CONTAINS"))
    }

    @Test("Operators Firestore lacks are refused, not approximated")
    func unsupported() {
        #expect(throws: FirebaseError.self) { try filterJSON(FirebaseFilterSpec(column: "name", op: "CONTAINS", value: "x"), types: ["name": "string"]) }
        #expect(throws: FirebaseError.self) { try filterJSON(FirebaseFilterSpec(column: "name", op: "ENDS WITH", value: "x")) }
        #expect(throws: FirebaseError.self) { try filterJSON(FirebaseFilterSpec(column: "name", op: "REGEX", value: "x")) }
        #expect(throws: FirebaseError.self) { try filterJSON(FirebaseFilterSpec(column: "age", op: "=", value: "old"), types: ["age": "integer"]) }
    }

    @Test("Several filters combine with the chosen logic, and a raw filter passes through")
    func combine() throws {
        let spec = FirebaseBrowseSpec(table: "users", filters: [
            FirebaseFilterSpec(column: "a", op: "=", value: "x"),
            FirebaseFilterSpec(column: "__RAW__", op: "", value: #"{"unaryFilter": {"field": {"fieldPath": "b.c"}, "op": "IS_NAN"}}"#)
        ], logicMode: "OR", limit: 10, offset: 0)
        let query = try FirestoreQueryBuilder.structuredQuery(
            spec: spec, target: try FirestoreCollectionTarget(table: "users"), documentRoot: testDocumentRoot, typeOf: noTypes
        )
        let filter = query["structuredQuery"]?["where"]?.text() ?? ""
        #expect(filter.hasPrefix(#"{"compositeFilter":{"filters":["#))
        #expect(filter.contains(#""op":"OR""#) && filter.contains("IS_NAN"))
        let bad = FirebaseBrowseSpec(table: "users", filters: [FirebaseFilterSpec(column: "__RAW__", op: "", value: "age > 3")], limit: 1, offset: 0)
        #expect(throws: FirebaseError.self) {
            try FirestoreQueryBuilder.structuredQuery(spec: bad, target: try FirestoreCollectionTarget(table: "users"), documentRoot: testDocumentRoot, typeOf: noTypes)
        }
    }

    @Test("Counting drops order and page")
    func count() throws {
        let spec = FirebaseBrowseSpec(table: "*/orders", sorts: [FirebaseSortSpec(column: "a", ascending: true)], limit: 10, offset: 5)
        let query = try FirestoreQueryBuilder.countQuery(
            spec: spec, target: try FirestoreCollectionTarget(table: spec.table), documentRoot: testDocumentRoot, typeOf: noTypes
        )
        let expected = #"{"structuredAggregationQuery":{"aggregations":[{"alias":"total","count":{}}],"#
            + #""structuredQuery":{"from":[{"allDescendants":true,"collectionId":"orders"}]}}}"#
        #expect(query.text() == expected)
    }

    @Test("Field paths are quoted when they need it")
    func fieldPaths() {
        #expect(FirestoreQueryBuilder.fieldPath("name") == "name")
        #expect(FirestoreQueryBuilder.fieldPath("first-name") == "`first-name`")
        #expect(FirestoreQueryBuilder.fieldPath("a`b") == "`a\\`b`")
        #expect(FirestoreQueryBuilder.fieldPath("__name__") == "__name__")
    }

    @Test("A table names a collection or a collection group, never a document")
    func targets() throws {
        #expect(try FirestoreCollectionTarget(table: "*/orders").isGroup)
        #expect(throws: FirebaseError.self) { try FirestoreCollectionTarget(table: "users/alice") }
        #expect(throws: FirebaseError.self) { try FirestoreCollectionTarget(table: "*/a/b") }
        let group = try FirestoreCollectionTarget(table: "*/orders")
        #expect(group.rowName(forDocumentPath: "users/a/orders/1") == "users/a/orders/1")
        let collection = try FirestoreCollectionTarget(table: "users")
        #expect(collection.rowName(forDocumentPath: "users/alice") == "alice")
        #expect(collection.documentPath(forRowName: "alice") == "users/alice")
    }
}
