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

    @Test("Equality matches a keyword as text, an integer as a number and a boolean as true or false")
    func equality() throws {
        #expect(try condition("city", "=", "Berlin") == #"{"key":"\"city\"","match":{"value":"Berlin"}}"#)
        #expect(try condition("count", "=", "7") == #"{"key":"\"count\"","match":{"value":7}}"#)
        #expect(try condition("active", "=", "1") == #"{"key":"\"active\"","match":{"value":true}}"#)
        #expect(throws: QdrantValueError.notAnInteger(column: "count", value: "x")) { try condition("count", "=", "x") }
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
        #expect(throws: QdrantFilterError.comparisonNeedsNumberOrDate(column: "note", op: ">")) {
            try condition("note", ">", "a")
        }
    }

    @Test("IN is the equality of each value: match any for strings or integers, ranges for floats")
    func inLists() throws {
        #expect(try condition("city", "IN", "Berlin, Paris") == #"{"key":"\"city\"","match":{"any":["Berlin","Paris"]}}"#)
        #expect(try condition("count", "IN", "1,2") == #"{"key":"\"count\"","match":{"any":[1,2]}}"#)
        #expect(try condition("pop", "IN", "1.5, 2.5")
            == #"{"should":[{"key":"\"pop\"","range":{"gte":1.5,"lte":1.5}},{"key":"\"pop\"","range":{"gte":2.5,"lte":2.5}}]}"#)
        #expect(try condition("active", "IN", "true")
            == #"{"should":[{"key":"\"active\"","match":{"value":true}}]}"#)
    }

    @Test("NOT IN excludes every value the way != excludes one")
    func notInLists() throws {
        #expect(try condition("count", "NOT IN", "1,2")
            == #"{"must_not":[{"key":"\"count\"","match":{"value":1}},{"key":"\"count\"","match":{"value":2}}]}"#)
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
        #expect(throws: QdrantFilterError.textMatchNeedsText(column: "count", type: "integer")) {
            try condition("count", "CONTAINS", "1")
        }
    }

    @Test("IS NULL matches a missing key as well as null, and IS EMPTY adds the empty string")
    func nullness() throws {
        #expect(try condition("note", "IS NULL") == #"{"is_empty":{"key":"\"note\""}}"#)
        #expect(try condition("note", "IS NOT NULL") == #"{"must_not":[{"is_empty":{"key":"\"note\""}}]}"#)
        #expect(try condition("note", "IS EMPTY")
            == #"{"should":[{"is_empty":{"key":"\"note\""}},{"key":"\"note\"","match":{"value":""}}]}"#)
        #expect(try condition("count", "IS EMPTY") == #"{"is_empty":{"key":"\"count\""}}"#)
    }

    @Test("The id column filters with has_id, keeping integer and UUID ids apart")
    func ids() throws {
        let uuid = "5c56c793-69f3-4fbf-87e6-c4bf54c28c26"
        #expect(try condition("id", "IN", "1, \(uuid)") == #"{"has_id":[1,"\#(uuid)"]}"#)
        #expect(try condition("id", "!=", "1") == #"{"must_not":[{"has_id":[1]}]}"#)
        #expect(throws: QdrantFilterError.notAPointID(value: "abc")) { try condition("id", "=", "abc") }
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
