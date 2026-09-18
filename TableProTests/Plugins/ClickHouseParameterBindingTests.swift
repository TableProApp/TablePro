//
//  ClickHouseParameterBindingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("ClickHouse Parameter Binding")
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

    @Test("A null parameter keeps its slot with no value")
    func nullParameterKeepsItsSlot() {
        let bound = ClickHouseParameterBinding.bind(
            query: "SELECT * FROM t WHERE a = ?",
            parameters: [.null]
        )
        #expect(bound.query == "SELECT * FROM t WHERE a = {p1:String}")
        #expect(bound.params["p1"] == .some(nil))
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
