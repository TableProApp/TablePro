import Foundation
@testable import TableProQdrantCore
import Testing

struct QdrantFilterBuilderTests {
    private func condition(_ column: String, _ op: String, _ value: String = "", _ second: String? = nil) throws -> String {
        canonical(try QdrantFilterBuilder.condition(for: QdrantFilterSpec(column: column, op: op, value: value, secondValue: second)))
    }

    @Test("Text matches as text alone")
    func textEquality() throws {
        #expect(try condition("city", "=", "Berlin") == #"{"key":"\"city\"","match":{"value":"Berlin"}}"#)
    }

    @Test("A value matches every type its text spells, whatever an index or a sample says the field holds")
    func everySpelling() throws {
        #expect(try condition("count", "=", "42")
            == #"{"should":[{"key":"\"count\"","match":{"value":"42"}},{"key":"\"count\"","range":{"gte":42,"lte":42}}]}"#)
        #expect(try condition("flag", "=", "1")
            == #"{"should":[{"key":"\"flag\"","match":{"value":"1"}},{"key":"\"flag\"","range":{"gte":1,"lte":1}},{"key":"\"flag\"","match":{"value":true}}]}"#)
        #expect(try condition("pop", "=", "3.5")
            == #"{"should":[{"key":"\"pop\"","match":{"value":"3.5"}},{"key":"\"pop\"","range":{"gte":3.5,"lte":3.5}}]}"#)
        #expect(try condition("count", "=", "9007199254740993")
            == #"{"should":[{"key":"\"count\"","match":{"value":"9007199254740993"}},{"key":"\"count\"","match":{"value":9007199254740993}}]}"#)
    }

    @Test("A key holding a dot stays one top-level key, and one holding a quote is refused")
    func keyQuoting() throws {
        #expect(try condition("a.b", "=", "x") == #"{"key":"\"a.b\"","match":{"value":"x"}}"#)
        #expect(throws: QdrantFilterError.keyNotAddressable(column: "q\"x")) { try condition("q\"x", "=", "1") }
    }

    @Test("Not equal nests the match under must_not")
    func notEqual() throws {
        #expect(try condition("city", "!=", "Berlin") == #"{"must_not":[{"key":"\"city\"","match":{"value":"Berlin"}}]}"#)
    }

    @Test("Comparisons and BETWEEN become a range on numbers, or on dates for other text")
    func ranges() throws {
        #expect(try condition("pop", ">", "2") == #"{"key":"\"pop\"","range":{"gt":2}}"#)
        #expect(try condition("count", "BETWEEN", "1,5", "5") == #"{"key":"\"count\"","range":{"gte":1,"lte":5}}"#)
        #expect(try condition("seen", ">=", "2024-01-02T00:00:00Z") == #"{"key":"\"seen\"","range":{"gte":"2024-01-02T00:00:00Z"}}"#)
        #expect(throws: QdrantFilterError.missingUpperBound(column: "count")) { try condition("count", "BETWEEN", "1", "") }
        #expect(throws: QdrantFilterError.boundNotExact(column: "count", value: "9007199254740993")) {
            try condition("count", ">=", "9007199254740993")
        }
    }

    @Test("IN collapses plain text to match any, and keeps every spelling of a number")
    func inLists() throws {
        #expect(try condition("city", "IN", "Berlin, Paris") == #"{"key":"\"city\"","match":{"any":["Berlin","Paris"]}}"#)
        #expect(try condition("rank", "IN", "1")
            == #"{"should":[{"should":[{"key":"\"rank\"","match":{"value":"1"}},{"key":"\"rank\"","range":{"gte":1,"lte":1}},{"key":"\"rank\"","match":{"value":true}}]}]}"#)
    }

    @Test("NOT IN excludes every value the way != excludes one")
    func notInLists() throws {
        #expect(try condition("city", "NOT IN", "a, b")
            == #"{"must_not":[{"key":"\"city\"","match":{"value":"a"}},{"key":"\"city\"","match":{"value":"b"}}]}"#)
    }

    @Test("CONTAINS matches words in any field, indexed or not, and a value that is not text matches nothing")
    func contains() throws {
        #expect(try condition("body", "CONTAINS", "vector") == #"{"key":"\"body\"","match":{"text":"vector"}}"#)
        #expect(try condition("rank", "CONTAINS", "1") == #"{"key":"\"rank\"","match":{"text":"1"}}"#)
    }

    @Test("IS NULL matches a missing key as well as null, and IS EMPTY adds the empty string")
    func nullness() throws {
        #expect(try condition("note", "IS NULL") == #"{"is_empty":{"key":"\"note\""}}"#)
        #expect(try condition("note", "IS NOT NULL") == #"{"must_not":[{"is_empty":{"key":"\"note\""}}]}"#)
        #expect(try condition("note", "IS EMPTY")
            == #"{"should":[{"is_empty":{"key":"\"note\""}},{"key":"\"note\"","match":{"value":""}}]}"#)
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

    @Test("Vectors cannot be filtered, contains on one finds nothing, and unsupported operators say so")
    func refusals() throws {
        #expect(throws: QdrantFilterError.vectorNotFilterable(column: "vector")) { try condition("vector", "=", "1") }
        #expect(try condition("vector.sp", "CONTAINS", "a") == #"{"has_id":[]}"#)
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
        let and = try #require(try QdrantFilterBuilder.filter(specs, logicMode: "AND"))
        let or = try #require(try QdrantFilterBuilder.filter(specs, logicMode: "OR"))
        #expect((and["must"] as? [Any])?.count == 2)
        #expect((or["should"] as? [Any])?.count == 2)
        #expect(try QdrantFilterBuilder.filter([], logicMode: "AND") == nil)
    }
}
