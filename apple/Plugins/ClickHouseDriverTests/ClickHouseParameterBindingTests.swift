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
}
