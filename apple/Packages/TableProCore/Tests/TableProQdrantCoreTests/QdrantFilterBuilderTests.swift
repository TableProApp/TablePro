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

    @Test("Equality matches a keyword as text and an integer as a number")
    func equality() throws {
        #expect(try condition("city", "=", "Berlin") == #"{"key":"city","match":{"value":"Berlin"}}"#)
        #expect(try condition("count", "=", "7") == #"{"key":"count","match":{"value":7}}"#)
        #expect(try condition("active", "=", "true") == #"{"key":"active","match":{"value":true}}"#)
    }

    @Test("A float has no exact match, so equality is the closed range around it")
    func floatEquality() throws {
        #expect(try condition("pop", "=", "3.5") == #"{"key":"pop","range":{"gte":3.5,"lte":3.5}}"#)
    }

    @Test("Not equal nests the match under must_not")
    func notEqual() throws {
        #expect(try condition("city", "!=", "Berlin") == #"{"must_not":[{"key":"city","match":{"value":"Berlin"}}]}"#)
    }

    @Test("Comparisons and BETWEEN become a range")
    func ranges() throws {
        #expect(try condition("pop", ">", "2") == #"{"key":"pop","range":{"gt":2}}"#)
        #expect(try condition("count", "BETWEEN", "1,5", "5") == #"{"key":"count","range":{"gte":1,"lte":5}}"#)
    }

    @Test("A comparison on a string field is refused, not sent")
    func comparisonOnText() {
        #expect(throws: QdrantFilterError.comparisonNeedsNumberOrDate(column: "note", op: ">")) {
            try condition("note", ">", "a")
        }
    }

    @Test("IN and NOT IN use match any and except")
    func lists() throws {
        #expect(try condition("city", "IN", "Berlin, Paris") == #"{"key":"city","match":{"any":["Berlin","Paris"]}}"#)
        #expect(try condition("count", "NOT IN", "1,2") == #"{"key":"count","match":{"except":[1,2]}}"#)
    }

    @Test("CONTAINS needs a full-text index, since Qdrant matches nothing without one")
    func contains() throws {
        #expect(try condition("body", "CONTAINS", "vector") == #"{"key":"body","match":{"text":"vector"}}"#)
        #expect(throws: QdrantFilterError.textMatchNeedsTextIndex(column: "city", op: "CONTAINS")) {
            try condition("city", "CONTAINS", "Ber")
        }
    }

    @Test("Null and empty checks")
    func nullness() throws {
        #expect(try condition("note", "IS NULL") == #"{"is_null":{"key":"note"}}"#)
        #expect(try condition("tags", "IS NOT EMPTY") == #"{"must_not":[{"is_empty":{"key":"tags"}}]}"#)
    }

    @Test("The id column filters with has_id, keeping integer and UUID ids apart")
    func ids() throws {
        let uuid = "5c56c793-69f3-4fbf-87e6-c4bf54c28c26"
        #expect(try condition("id", "IN", "1, \(uuid)") == #"{"has_id":[1,"\#(uuid)"]}"#)
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
