//
//  PostgresArrayLiteralCodecTests.swift
//  TableProTests
//
//  Tests for parsing and serializing PostgreSQL array literals.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Postgres Array Literal Codec")
struct PostgresArrayLiteralCodecTests {
    private let hostileLiteral =
        #"{"a,b","has \"quote\"","back\\slash"," lead","trail ","","NULL","null","{brace}",NULL}"#

    private var hostileElements: [PostgresArrayElement] {
        [
            .value("a,b"),
            .value("has \"quote\""),
            .value("back\\slash"),
            .value(" lead"),
            .value("trail "),
            .value(""),
            .value("NULL"),
            .value("null"),
            .value("{brace}"),
            .null
        ]
    }

    @Test("Parses every hostile element form PostgreSQL emits")
    func parsesHostileLiteral() throws {
        let parsed = try #require(PostgresArrayLiteralCodec.parse(hostileLiteral))
        #expect(parsed == hostileElements)
    }

    @Test("Serializes back to the exact literal PostgreSQL produced")
    func serializesHostileLiteral() {
        #expect(PostgresArrayLiteralCodec.serialize(hostileElements) == hostileLiteral)
    }

    @Test("Round-trips without drift")
    func roundTripsHostileLiteral() throws {
        let parsed = try #require(PostgresArrayLiteralCodec.parse(hostileLiteral))
        let serialized = PostgresArrayLiteralCodec.serialize(parsed)
        let reparsed = try #require(PostgresArrayLiteralCodec.parse(serialized))
        #expect(reparsed == hostileElements)
    }

    @Test("Empty array is distinct from a null element")
    func parsesEmptyArray() {
        #expect(PostgresArrayLiteralCodec.parse("{}")?.isEmpty == true)
        #expect(PostgresArrayLiteralCodec.parse("{ }")?.isEmpty == true)
        #expect(PostgresArrayLiteralCodec.parse("{NULL}") == [.null])
        #expect(PostgresArrayLiteralCodec.serialize([]) == "{}")
    }

    @Test("Bare NULL is SQL NULL in any case, quoted NULL is the four-character string")
    func distinguishesNullForms() {
        #expect(PostgresArrayLiteralCodec.parse("{NULL}") == [.null])
        #expect(PostgresArrayLiteralCodec.parse("{null}") == [.null])
        #expect(PostgresArrayLiteralCodec.parse("{NuLl}") == [.null])
        #expect(PostgresArrayLiteralCodec.parse(#"{"NULL"}"#) == [.value("NULL")])
        #expect(PostgresArrayLiteralCodec.parse(#"{\N\U\L\L}"#) == [.value("NULL")])
    }

    @Test("Unquoted whitespace is trimmed, quoted whitespace is kept")
    func handlesWhitespace() {
        #expect(PostgresArrayLiteralCodec.parse("{  a ,  b  }") == [.value("a"), .value("b")])
        #expect(PostgresArrayLiteralCodec.parse(#"{ "  a  " }"#) == [.value("  a  ")])
        #expect(PostgresArrayLiteralCodec.parse(#"{\ }"#) == [.value(" ")])
    }

    @Test("Backslash escaping is accepted as an alternative to quoting")
    func acceptsBackslashEscaping() {
        #expect(PostgresArrayLiteralCodec.parse(#"{a\,b," x "}"#) == [.value("a,b"), .value(" x ")])
    }

    @Test("Order and duplicate elements survive a round trip")
    func preservesOrderAndDuplicates() {
        let elements: [PostgresArrayElement] = [.value("b"), .value("a"), .value("b")]
        let serialized = PostgresArrayLiteralCodec.serialize(elements)
        #expect(serialized == "{b,a,b}")
        #expect(PostgresArrayLiteralCodec.parse(serialized) == elements)
    }

    @Test("Shapes the element editor cannot represent are rejected")
    func rejectsUnsupportedShapes() {
        #expect(PostgresArrayLiteralCodec.parse("[0:2]={a,b,c}") == nil)
        #expect(PostgresArrayLiteralCodec.parse("{{1,2},{3,4}}") == nil)
    }

    @Test("Malformed literals are rejected rather than silently accepted")
    func rejectsMalformedLiterals() {
        #expect(PostgresArrayLiteralCodec.parse("{,}") == nil)
        #expect(PostgresArrayLiteralCodec.parse("{a,  ,b}") == nil)
        #expect(PostgresArrayLiteralCodec.parse("{a, }") == nil)
        #expect(PostgresArrayLiteralCodec.parse("{a,b") == nil)
        #expect(PostgresArrayLiteralCodec.parse("{a,b} trailing") == nil)
        #expect(PostgresArrayLiteralCodec.parse("hello") == nil)
        #expect(PostgresArrayLiteralCodec.parse("") == nil)
    }

    @Test("An empty string element must stay quoted")
    func keepsEmptyStringElementQuoted() {
        #expect(PostgresArrayLiteralCodec.parse(#"{""}"#) == [.value("")])
        #expect(PostgresArrayLiteralCodec.serialize([.value("")]) == #"{""}"#)
    }

    @Test("The delimiter comes from the element type, not a hardcoded comma")
    func honoursElementDelimiter() {
        let boxes = "{(1,1),(0,0);(3,3),(2,2)}"
        let parsed = PostgresArrayLiteralCodec.parse(boxes, delimiter: ";")
        #expect(parsed == [.value("(1,1),(0,0)"), .value("(3,3),(2,2)")])
    }

    @Test("A value needing quotes under one delimiter may not need them under another")
    func quotesAccordingToDelimiter() {
        #expect(PostgresArrayLiteralCodec.serialize([.value("a,b")], delimiter: ";") == "{a,b}")
        #expect(PostgresArrayLiteralCodec.serialize([.value("a,b")]) == #"{"a,b"}"#)
    }
}
