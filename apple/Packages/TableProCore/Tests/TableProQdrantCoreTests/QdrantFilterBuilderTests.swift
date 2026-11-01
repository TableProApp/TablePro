import Foundation
@testable import TableProQdrantCore
import Testing

struct QdrantFilterBuilderTests {
    private func condition(_ column: String, _ op: String, _ value: String = "", _ second: String? = nil) throws -> String {
        canonical(try QdrantFilterBuilder.condition(
            for: QdrantFilterSpec(column: column, op: op, value: value, secondValue: second),
            collection: sampleCollection
        ))
    }

    @Test("An indexed field matches as its index's type")
    func indexedEquality() throws {
        #expect(try condition("city", "=", "Berlin") == #"{"key":"\"city\"","match":{"value":"Berlin"}}"#)
        #expect(try condition("rank", "=", "7") == #"{"key":"\"rank\"","match":{"value":7}}"#)
        #expect(try condition("flag", "=", "1") == #"{"key":"\"flag\"","match":{"value":true}}"#)
        #expect(throws: QdrantValueError.notAnInteger(column: "rank", value: "x")) { try condition("rank", "=", "x") }
    }

    @Test("A field nobody indexed matches every type its text can spell, whatever the sample guessed")
    func unindexedEquality() throws {
        #expect(try condition("count", "=", "42")
            == #"{"should":[{"key":"\"count\"","match":{"value":"42"}},{"key":"\"count\"","range":{"gte":42,"lte":42}}]}"#)
        #expect(try condition("note", "=", "1")
            == #"{"should":[{"key":"\"note\"","match":{"value":"1"}},{"key":"\"note\"","range":{"gte":1,"lte":1}},{"key":"\"note\"","match":{"value":true}}]}"#)
        #expect(try condition("note", "=", "Berlin") == #"{"key":"\"note\"","match":{"value":"Berlin"}}"#)
        #expect(try condition("count", "=", "9007199254740993")
            == #"{"should":[{"key":"\"count\"","match":{"value":"9007199254740993"}},{"key":"\"count\"","match":{"value":9007199254740993}}]}"#)
    }

    @Test("A key holding a dot stays one top-level key, and one holding a quote is refused")
    func keyQuoting() throws {
        #expect(try condition("a.b", "=", "x") == #"{"key":"\"a.b\"","match":{"value":"x"}}"#)
        let collection = QdrantCollection(name: "docs", vectors: [], payloadFields: [
            QdrantPayloadField(name: "q\"x", type: .string, isIndexed: false)
        ])
        #expect(throws: QdrantFilterError.keyNotAddressable(column: "q\"x")) {
            try QdrantFilterBuilder.condition(for: QdrantFilterSpec(column: "q\"x", op: "=", value: "1"), collection: collection)
        }
    }

    @Test("A float and a datetime have no exact match, so equality is the closed range around the value")
    func rangeEquality() throws {
        #expect(try condition("pop", "=", "3.5") == #"{"key":"\"pop\"","range":{"gte":3.5,"lte":3.5}}"#)
        #expect(try condition("seen", "=", "2024-01-02T00:00:00Z")
            == #"{"key":"\"seen\"","range":{"gte":"2024-01-02T00:00:00Z","lte":"2024-01-02T00:00:00Z"}}"#)
    }

    @Test("Not equal nests the match under must_not")
    func notEqual() throws {
        #expect(try condition("city", "!=", "Berlin") == #"{"must_not":[{"key":"\"city\"","match":{"value":"Berlin"}}]}"#)
    }

    @Test("Comparisons and BETWEEN become a range, and text is refused")
    func ranges() throws {
        #expect(try condition("pop", ">", "2") == #"{"key":"\"pop\"","range":{"gt":2}}"#)
        #expect(try condition("count", "BETWEEN", "1,5", "5") == #"{"key":"\"count\"","range":{"gte":1,"lte":5}}"#)
        #expect(throws: QdrantFilterError.comparisonNeedsNumberOrDate(column: "city", op: ">")) {
            try condition("city", ">", "a")
        }
    }

    @Test("IN is the equality of each value: match any for strings or integers, ranges for floats")
    func inLists() throws {
        #expect(try condition("city", "IN", "Berlin, Paris") == #"{"key":"\"city\"","match":{"any":["Berlin","Paris"]}}"#)
        #expect(try condition("rank", "IN", "1,2") == #"{"key":"\"rank\"","match":{"any":[1,2]}}"#)
        #expect(try condition("note", "IN", "a, b") == #"{"key":"\"note\"","match":{"any":["a","b"]}}"#)
        #expect(try condition("pop", "IN", "1.5, 2.5")
            == #"{"should":[{"key":"\"pop\"","range":{"gte":1.5,"lte":1.5}},{"key":"\"pop\"","range":{"gte":2.5,"lte":2.5}}]}"#)
        #expect(try condition("flag", "IN", "true")
            == #"{"should":[{"key":"\"flag\"","match":{"value":true}}]}"#)
    }

    @Test("NOT IN excludes every value the way != excludes one")
    func notInLists() throws {
        #expect(try condition("rank", "NOT IN", "1,2")
            == #"{"must_not":[{"key":"\"rank\"","match":{"value":1}},{"key":"\"rank\"","match":{"value":2}}]}"#)
        #expect(try condition("pop", "NOT IN", "1.5") == #"{"must_not":[{"key":"\"pop\"","range":{"gte":1.5,"lte":1.5}}]}"#)
    }

    @Test("A geo point cannot be matched whole")
    func geoEquality() {
        #expect(throws: QdrantFilterError.wholeValueNotMatchable(column: "home", type: "geo")) {
            try condition("home", "IN", "1")
        }
    }

    @Test("CONTAINS matches words in any text field, indexed or not, and refuses numbers")
    func contains() throws {
        #expect(try condition("body", "CONTAINS", "vector") == #"{"key":"\"body\"","match":{"text":"vector"}}"#)
        #expect(try condition("note", "CONTAINS", "Ber") == #"{"key":"\"note\"","match":{"text":"Ber"}}"#)
        #expect(throws: QdrantFilterError.textMatchNeedsText(column: "rank", type: "integer")) {
            try condition("rank", "CONTAINS", "1")
        }
        #expect(try condition("count", "CONTAINS", "1") == #"{"key":"\"count\"","match":{"text":"1"}}"#)
    }

    @Test("IS NULL matches a missing key as well as null, and IS EMPTY adds the empty string")
    func nullness() throws {
        #expect(try condition("note", "IS NULL") == #"{"is_empty":{"key":"\"note\""}}"#)
        #expect(try condition("note", "IS NOT NULL") == #"{"must_not":[{"is_empty":{"key":"\"note\""}}]}"#)
        #expect(try condition("note", "IS EMPTY")
            == #"{"should":[{"is_empty":{"key":"\"note\""}},{"key":"\"note\"","match":{"value":""}}]}"#)
        #expect(try condition("rank", "IS EMPTY") == #"{"is_empty":{"key":"\"rank\""}}"#)
    }

    @Test("The id column filters with has_id, keeping integer and UUID ids apart")
    func ids() throws {
        let uuid = "5c56c793-69f3-4fbf-87e6-c4bf54c28c26"
        #expect(try condition("id", "IN", "1, \(uuid)") == #"{"has_id":[1,"\#(uuid)"]}"#)
        #expect(try condition("id", "!=", "1") == #"{"must_not":[{"has_id":[1]}]}"#)
        #expect(throws: QdrantFilterError.notAPointID(value: "abc")) { try condition("id", "=", "abc") }
        #expect(try condition("id", "CONTAINS", "7") == #"{"has_id":[7]}"#)
        #expect(try condition("id", "CONTAINS", "Berlin") == #"{"has_id":[]}"#)
    }

    @Test("Vectors cannot be filtered and unsupported operators say so")
    func refusals() {
        #expect(throws: QdrantFilterError.vectorNotFilterable(column: "vector")) { try condition("vector", "=", "1") }
        #expect(throws: QdrantFilterError.unsupportedOperator("STARTS WITH")) { try condition("city", "STARTS WITH", "B") }
    }

    @Test("A raw row is a Qdrant condition in JSON")
    func raw() throws {
        #expect(try condition("__RAW__", "", #"{"key":"city","match":{"value":"X"}}"#) == #"{"key":"city","match":{"value":"X"}}"#)
        #expect(throws: QdrantFilterError.rawFilterNotAnObject) { try condition("__RAW__", "", "city = 1") }
    }

    @Test("AND rows go under must and OR rows under should")
    func logic() throws {
        let specs = [
            QdrantFilterSpec(column: "city", op: "=", value: "Berlin"),
            QdrantFilterSpec(column: "count", op: "<", value: "3")
        ]
        let and = try #require(try QdrantFilterBuilder.filter(specs, logicMode: "AND", collection: sampleCollection))
        let or = try #require(try QdrantFilterBuilder.filter(specs, logicMode: "OR", collection: sampleCollection))
        #expect((and["must"] as? [Any])?.count == 2)
        #expect((or["should"] as? [Any])?.count == 2)
        #expect(try QdrantFilterBuilder.filter([], logicMode: "AND", collection: sampleCollection) == nil)
    }
}
