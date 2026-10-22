//
//  ClickHouseParameterBindingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct ClickHouseParameterBindingTests {
    @Test("Text parameters become named HTTP substitutions")
    func textParametersBecomeNamedSubstitutions() {
        let bound = ClickHouseParameterBinding.bind(
            query: "SELECT * FROM t WHERE a = ? AND b = ?",
            parameters: [.text("one"), .text("two")]
        )
        #expect(bound.query == "SELECT * FROM t WHERE a = {p1:String} AND b = {p2:String}")
        #expect(bound.params["p1"] == "one")
        #expect(bound.params["p2"] == "two")
    }

    // Measured on ClickHouse 25.8: `C:\new` sent as it is arrived as `C:`, a newline and `ew`, and a raw tab was refused.
    @Test("A text parameter is sent in the escaped form ClickHouse reads it in")
    func textParametersAreEscaped() {
        let bound = ClickHouseParameterBinding.bind(
            query: "SELECT ?, ?",
            parameters: [.text(#"C:\new\table"#), .text("a\tb\nc\rd\u{0}e")]
        )
        #expect(bound.params["p1"] == #"C:\\new\\table"#)
        #expect(bound.params["p2"] == #"a\tb\nc\rd\0e"#)
    }

    // A String parameter cannot hold NULL: sent with no value it reaches a Nullable column as '' and fails a number.
    @Test("A null parameter is written into the statement as NULL")
    func nullParameterIsInlinedAsNull() {
        let bound = ClickHouseParameterBinding.bind(
            query: "ALTER TABLE t UPDATE a = ?, b = ? WHERE id = ?",
            parameters: [.null, .text("x"), .text("7")]
        )
        #expect(bound.query == "ALTER TABLE t UPDATE a = NULL, b = {p1:String} WHERE id = {p2:String}")
        #expect(bound.params == ["p1": "x", "p2": "7"])
    }

    @Test("Text is sent in the server's escaped format, so a backslash, tab or line break arrives as typed")
    func textIsEscapedForTheServer() {
        let bound = ClickHouseParameterBinding.bind(
            query: "SELECT ?",
            parameters: [.text("a\\nb\tc\nd\re\\")]
        )
        #expect(bound.params["p1"] == "a\\\\nb\\tc\\nd\\re\\\\")
    }

    @Test("A binary parameter is written into the statement as unhex, never as text")
    func binaryParameterBecomesUnhex() {
        let bound = ClickHouseParameterBinding.bind(
            query: "ALTER TABLE t DELETE WHERE raw = ?",
            parameters: [.bytes(Data([0xDE, 0xAD, 0xBE, 0xEF]))]
        )
        #expect(bound.query == "ALTER TABLE t DELETE WHERE raw = unhex('DEADBEEF')")
        #expect(bound.params.isEmpty)
    }

    @Test("Named numbering stays contiguous when a binary parameter is inlined")
    func namedNumberingSkipsInlinedBinary() {
        let bound = ClickHouseParameterBinding.bind(
            query: "ALTER TABLE t UPDATE txt = ? WHERE raw = ? AND id = ?",
            parameters: [.text("new"), .bytes(Data([0x01, 0x02])), .text("7")]
        )
        #expect(bound.query == "ALTER TABLE t UPDATE txt = {p1:String} WHERE raw = unhex('0102') AND id = {p2:String}")
        #expect(bound.params["p1"] == "new")
        #expect(bound.params["p2"] == "7")
        #expect(bound.params.count == 2)
    }

    @Test("An empty binary value is still a binary literal")
    func emptyBinaryParameterIsALiteral() {
        let bound = ClickHouseParameterBinding.bind(
            query: "SELECT ?",
            parameters: [.bytes(Data())]
        )
        #expect(bound.query == "SELECT unhex('')")
    }

    @Test("A question mark inside a string literal is not a placeholder")
    func questionMarkInsideALiteralIsNotAPlaceholder() {
        let bound = ClickHouseParameterBinding.bind(
            query: "SELECT * FROM t WHERE a = 'why?' AND b = ?",
            parameters: [.text("x")]
        )
        #expect(bound.query == "SELECT * FROM t WHERE a = 'why?' AND b = {p1:String}")
        #expect(bound.params["p1"] == "x")
    }

    @Test("A question mark inside a backquoted name is not a placeholder")
    func questionMarkInsideABackquotedNameIsNotAPlaceholder() {
        let bound = ClickHouseParameterBinding.bind(
            query: "ALTER TABLE `orders` UPDATE `is_paid?` = ? WHERE `id` = ? AND `is_paid?` = ?",
            parameters: [.text("1"), .text("7"), .text("0")]
        )
        #expect(bound.query == "ALTER TABLE `orders` UPDATE `is_paid?` = {p1:String} WHERE `id` = {p2:String} AND `is_paid?` = {p3:String}")
        #expect(bound.params == ["p1": "1", "p2": "7", "p3": "0"])
    }

    @Test("A single quote inside a backquoted name does not open a string literal")
    func singleQuoteInsideABackquotedNameIsOpaque() {
        let bound = ClickHouseParameterBinding.bind(
            query: "ALTER TABLE `orders` UPDATE `l'adresse` = ? WHERE `id` = ? AND `l'adresse` = ?",
            parameters: [.text("NEW"), .text("7"), .text("OLD")]
        )
        #expect(bound.query == "ALTER TABLE `orders` UPDATE `l'adresse` = {p1:String} WHERE `id` = {p2:String} AND `l'adresse` = {p3:String}")
        #expect(bound.params == ["p1": "NEW", "p2": "7", "p3": "OLD"])
    }

    @Test("Names quoted with escaped backquotes, backslashes or a leading combining mark stay opaque")
    func escapedBackquotedNamesStayOpaque() {
        let names = ["a`b?", "c\\", "\u{301}d'?"].map(clickHouseQuotedIdentifier)
        let bound = ClickHouseParameterBinding.bind(
            query: "ALTER TABLE \(names[0]) UPDATE \(names[1]) = ? WHERE \(names[2]) = ?",
            parameters: [.text("x"), .text("y")]
        )
        #expect(bound.query == "ALTER TABLE \(names[0]) UPDATE \(names[1]) = {p1:String} WHERE \(names[2]) = {p2:String}")
        #expect(bound.params == ["p1": "x", "p2": "y"])
    }

    @Test("Extra placeholders past the parameter list are left alone")
    func extraPlaceholdersAreLeftAlone() {
        let bound = ClickHouseParameterBinding.bind(
            query: "SELECT ?, ?",
            parameters: [.text("only")]
        )
        #expect(bound.query == "SELECT {p1:String}, ?")
    }

    @Test("The hex a binary parameter produces cannot close the literal it sits in")
    func hexLiteralIsAlphanumericOnly() {
        let literal = ClickHouseParameterBinding.hexLiteral(Data([0x27, 0x5C, 0x00, 0xFF]))
        #expect(literal == "unhex('275C00FF')")
    }

    // #3777, measured on 25.8: a `param_` item over 131,072 encoded bytes got HTTP 500 and a URL over 1 MiB HTTP 400.
    @Test("A value too long for the URL writes every value of the statement into it")
    func longValueIsWrittenIntoTheStatement() {
        let long = String(repeating: "x", count: ClickHouseParameterBinding.maxParameterBytes + 1)
        let bound = ClickHouseParameterBinding.bind(
            query: "ALTER TABLE t UPDATE s = ?, n = ? WHERE id = ?",
            parameters: [.text(long), .null, .text("it's")]
        )
        #expect(bound.query == "ALTER TABLE t UPDATE s = '\(long)', n = NULL WHERE id = 'it''s'")
        #expect(bound.params.isEmpty)
    }

    @Test("Values that fit one by one but not together go into the statement")
    func manyValuesOverTheURLBudgetAreWrittenIn() {
        let value = String(repeating: "y", count: 120_000)
        let parameters = [PluginCellValue](repeating: .text(value), count: 9)
        let bound = ClickHouseParameterBinding.bind(
            query: "SELECT " + Array(repeating: "?", count: 9).joined(separator: ", "), parameters: parameters
        )
        #expect(bound.params.isEmpty)
        #expect(bound.query.hasPrefix("SELECT '\(value)', "))
    }

    @Test("The URL budget counts each item's name and separators, which a wide batch of short values is mostly made of")
    func urlBudgetCountsItemNames() {
        let count = 70_000
        let bound = ClickHouseParameterBinding.bind(
            query: "INSERT INTO t VALUES (" + Array(repeating: "?", count: count).joined(separator: "), (") + ")",
            parameters: Array(repeating: .text("&"), count: count)
        )
        #expect(bound.params.isEmpty)
        #expect(bound.query.hasPrefix("INSERT INTO t VALUES (CAST('&' AS String)), "))
    }

    // Percent-encoding triples every byte outside A-Z, a-z, 0-9 and `-._~`, and the server counts the encoded form.
    @Test("The URL budget counts percent-encoded bytes")
    func urlBudgetCountsEncodedBytes() {
        let euros = String(repeating: "\u{20AC}", count: 15_000)
        #expect(ClickHouseParameterBinding.urlEncodedByteCount(euros) == 135_000)
        #expect(ClickHouseParameterBinding.urlEncodedByteCount("a+b c") == 9)
        #expect(ClickHouseParameterBinding.bind(query: "SELECT ?", parameters: [.text(euros)]).params.isEmpty)
    }

    // Measured on 25.8: a braced UUID as a plain literal in VALUES was stored as another UUID; the cast refused it.
    @Test("Long text in INSERT data is a String cast, and only there")
    func longInsertDataIsCast() {
        let long = String(repeating: "z", count: 140_000)
        let insert = ClickHouseParameterBinding.bind(
            query: "INSERT INTO `t` (`a`, `b`, `c`) VALUES (?, ?, ?)",
            parameters: [.text(long), .bytes(Data([0x01])), .text("{6f9619ff-8b86-d011-b42d-00c04fc964ff}")]
        )
        let identified = ClickHouseParameterBinding.bind(query: "CREATE USER u IDENTIFIED BY ?", parameters: [.text(long)])
        let insertSelect = ClickHouseParameterBinding.bind(
            query: "/* copy */ insert into t select * from s where s = ?", parameters: [.text(long)]
        )
        #expect(insert.query == "INSERT INTO `t` (`a`, `b`, `c`) VALUES (CAST('\(long)' AS String), unhex('01'), "
            + "CAST('{6f9619ff-8b86-d011-b42d-00c04fc964ff}' AS String))")
        #expect(identified.query == "CREATE USER u IDENTIFIED BY '\(long)'")
        #expect(insertSelect.query == "/* copy */ insert into t select * from s where s = '\(long)'")
    }

    // Measured on 25.8: each of these reads back as the text that was bound.
    @Test("A quote, backslash or control character cannot end a written-in literal")
    func writtenInLiteralsAreEscaped() {
        let padding = String(repeating: "p", count: 140_000)
        let bound = ClickHouseParameterBinding.bind(
            query: "SELECT ?, ?, ?, ?",
            parameters: [.text(padding), .text(#"C:\new\table"#), .text("a\tb\nc\rd\u{0}e\u{08}f\u{0C}g\u{1A}"), .text("'\u{301}) OR 1 = 1 --")]
        )
        let expected = [padding, #"C:\\new\\table"#, #"a\tb\nc\rd\0e\bf\fg"# + "\u{1A}", "''\u{301}) OR 1 = 1 --"]
        #expect(bound.query == "SELECT " + expected.map { "'\($0)'" }.joined(separator: ", "))
    }

    // SQLParameterExtractor writes no `?` inside these, so a `?` or a quote in one is the user's own text.
    @Test("A quote or question mark in a comment or a dollar-quoted body is not a placeholder")
    func commentsAndDollarQuotesAreSkipped() {
        let bound = ClickHouseParameterBinding.bind(
            query: "-- customer's orders?\nSELECT /* why? it's */ $$it's ?$$, $t$?$t$, $1 FROM t WHERE id = ?",
            parameters: [.text("7")]
        )
        #expect(bound.query == "-- customer's orders?\nSELECT /* why? it's */ $$it's ?$$, $t$?$t$, $1 FROM t WHERE id = {p1:String}")
        #expect(bound.params == ["p1": "7"])
    }
}
