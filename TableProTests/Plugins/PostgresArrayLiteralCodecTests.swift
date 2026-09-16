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

    /// Every literal below came off a live PostgreSQL 17.11 for the `jsonb[]` shapes in #2897. A
    /// JSON element carries a second layer of escaping, which is why the element editor excluded
    /// these columns; the array quoting round-trips it exactly, which is why it no longer does.
    @Test("Round-trips the jsonb[] literals PostgreSQL emits, byte for byte")
    func roundTripsJsonbArrayLiterals() throws {
        let literals = [
            #"{"{\"id\": 1, \"name\": \"example\", \"metadata\": {\"tags\": [\"one\", \"two\"], \"enabled\": true}}","{\"id\": 2, \"name\": \"another\"}"}"#,
            #"{1,true,"\"hello\"","\"has \\\"quote\\\"\"","\"a,b\"","[1, 2]","{}",[]}"#,
            #"{"{\"p\": \"back\\\\slash\"}","{\"p\": \"tab\\there\"}"}"#,
            #"{"\"{a,b}\""}"#,
            #"{"{\"unicode\": \"café ❤\"}"}"#,
            #"{"{\"nested\": {\"deep\": [1, {\"x\": null}]}}",NULL,[]}"#,
            #"{"\"  lead and trail  \""}"#,
            #"{"\"\""}"#,
            #"{"{\"newline\": \"a\\nb\"}"}"#,
            "{}"
        ]
        for literal in literals {
            let parsed = try #require(PostgresArrayLiteralCodec.parse(literal), Comment(rawValue: literal))
            #expect(PostgresArrayLiteralCodec.serialize(parsed) == literal, Comment(rawValue: literal))
        }
    }

    /// PostgreSQL quotes an element whose text would read back as the NULL keyword, so a JSON null
    /// arrives as `"null"` and only a bare `NULL` is a SQL NULL. Collapsing the two is what
    /// `to_jsonb()` does, and why it cannot stand in for editing the column.
    @Test("A SQL NULL element and a JSON null element stay distinct")
    func separatesSqlNullFromJsonNull() throws {
        let literal = #"{NULL,"null","\"null\"","\"NULL\""}"#
        let parsed = try #require(PostgresArrayLiteralCodec.parse(literal))
        #expect(parsed == [.null, .value("null"), .value("\"null\""), .value("\"NULL\"")])
        #expect(PostgresArrayLiteralCodec.serialize(parsed) == literal)
    }

    /// Measured on PostgreSQL 17.11: `array_in` trims these six around an unquoted element and
    /// `array_out` quotes an element containing any of them.
    @Test("The six characters PostgreSQL treats as whitespace are trimmed")
    func trimsPostgresWhitespace() {
        for separator in [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"] {
            let literal = "{\(separator)abc\(separator),def}"
            #expect(
                PostgresArrayLiteralCodec.parse(literal) == [.value("abc"), .value("def")],
                Comment(rawValue: literal.debugDescription)
            )
        }
    }

    /// The codec scans Unicode scalars because the server does. A Swift grapheme can carry a
    /// structural scalar and a combining mark together, and every one of these cases is a
    /// `Character` that compares equal to nothing the parser is looking for.
    @Test("Scanning follows scalars, not graphemes")
    func scansScalarsRatherThanGraphemes() {
        let crlf = [PostgresArrayElement.value("\r\nabc")]
        #expect(PostgresArrayLiteralCodec.serialize(crlf) == "{\"\r\nabc\"}")
        #expect(PostgresArrayLiteralCodec.parse("{\r\nabc,def}") == [.value("abc"), .value("def")])

        let combiningAfterSpace = [PostgresArrayElement.value(" \u{0301}abc")]
        #expect(PostgresArrayLiteralCodec.serialize(combiningAfterSpace) == "{\" \u{0301}abc\"}")

        #expect(PostgresArrayLiteralCodec.parse("{a,\u{0301}b}") == [.value("a"), .value("\u{0301}b")])
        #expect(PostgresArrayLiteralCodec.serialize([.value("a,\u{0301}b")]) == #"{"a,\#u{0301}b"}"#)
    }

    /// Measured on the same server: `array_out` writes U+00A0 and U+3000 unquoted and `array_in`
    /// reads them back as part of the value. Trimming them here deleted a character from an element
    /// the user had not touched, because committing the editor re-serializes every row.
    @Test("Unicode whitespace PostgreSQL keeps is neither trimmed nor quoted")
    func keepsUnicodeWhitespace() {
        let nonBreaking = [PostgresArrayElement.value("\u{00A0}abc"), .value("def")]
        #expect(PostgresArrayLiteralCodec.parse("{\u{00A0}abc,def}") == nonBreaking)
        #expect(PostgresArrayLiteralCodec.serialize(nonBreaking) == "{\u{00A0}abc,def}")

        let ideographic = [PostgresArrayElement.value("abc\u{3000}"), .value("def")]
        #expect(PostgresArrayLiteralCodec.parse("{abc\u{3000},def}") == ideographic)
        #expect(PostgresArrayLiteralCodec.serialize(ideographic) == "{abc\u{3000},def}")
    }
}
