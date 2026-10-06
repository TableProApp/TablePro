//
//  OracleBindPlaceholdersTests.swift
//  TableProTests
//
//  The host's `?` placeholders on Oracle: a value a literal can carry is the literal the PluginKit default writes, and
//  only what no literal can carry is bound as `:n`. A `?` that is text stays text. The literal limit and the binds
//  were measured on Oracle 23ai.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OracleBindPlaceholdersTests {
    private static let bytes = PluginCellValue.bytes(Data([0xDE, 0xAD]))

    private func substituted(_ sql: String, _ parameters: [PluginCellValue]) -> String {
        OracleBindPlaceholders.substituting(sql, parameters: parameters).sql
    }

    @Test("Text, numbers and NULL are the literals the PluginKit default writes")
    func literals() {
        let statement = OracleBindPlaceholders.substituting(
            "INSERT INTO \"T\" (\"A\", \"B\", \"C\", \"D\") VALUES (?, ?, ?, ?)",
            parameters: [.text("it's"), .text("12.5"), .null, .text("00123")]
        )
        #expect(statement.sql == "INSERT INTO \"T\" (\"A\", \"B\", \"C\", \"D\") VALUES ('it''s', 12.5, NULL, 00123)")
        #expect(statement.binds.isEmpty)
    }

    /// Oracle has no `X'..'` literal (ORA-03046).
    @Test("Bytes are bound, numbered densely among the literals")
    func bytesAreBound() {
        let other = PluginCellValue.bytes(Data([0x01]))
        let statement = OracleBindPlaceholders.substituting(
            "UPDATE \"T\" SET \"R\" = ?, \"V\" = ?, \"B\" = ? WHERE \"ID\" = ?",
            parameters: [Self.bytes, .text("x"), other, .text("7")]
        )
        #expect(statement.sql == "UPDATE \"T\" SET \"R\" = :1, \"V\" = 'x', \"B\" = :2 WHERE \"ID\" = 7")
        #expect(statement.binds == [Self.bytes, other])
    }

    /// 4,000 bytes parse and 4,001 fail with ORA-01704, counted on the value and not on its doubled quotes.
    @Test("Text over the 4,000-byte literal limit is bound")
    func longTextIsBound() {
        let atLimit = String(repeating: "a", count: 3_999) + "'"
        #expect(OracleBindPlaceholders.literal(for: .text(atLimit)) == "'" + String(repeating: "a", count: 3_999) + "'''")
        #expect(OracleBindPlaceholders.literal(for: .text(String(repeating: "a", count: 4_001))) == nil)
        #expect(OracleBindPlaceholders.literal(for: .text(String(repeating: "\u{1EBF}", count: 1_333))) != nil)
        #expect(OracleBindPlaceholders.literal(for: .text(String(repeating: "\u{1EBF}", count: 1_334))) == nil)

        let long = PluginCellValue.text(String(repeating: "x", count: 5_000))
        let statement = OracleBindPlaceholders.substituting("INSERT INTO \"T\" (\"C\", \"A\") VALUES (?, ?)", parameters: [long, .text("1")])
        #expect(statement.sql == "INSERT INTO \"T\" (\"C\", \"A\") VALUES (:1, 1)")
        #expect(statement.binds == [long])
    }

    @Test("A quote carrying a combining mark is still doubled, and NUL is dropped")
    func quoteEscaping() {
        #expect(OracleBindPlaceholders.literal(for: .text("a'\u{0301}b")) == "'a''\u{0301}b'")
        #expect(OracleBindPlaceholders.literal(for: .text("a\u{0}b")) == "'ab'")
    }

    @Test("A question mark inside a string literal is text")
    func stringLiteral() {
        #expect(substituted("SELECT '?', 'it''s ?' FROM dual WHERE a = ?", [Self.bytes])
            == "SELECT '?', 'it''s ?' FROM dual WHERE a = :1")
    }

    @Test("A question mark inside an alternative-quoted literal is text, whatever the delimiter")
    func alternativeQuotes() {
        #expect(substituted("SELECT q'[?]' FROM dual WHERE a = ?", [Self.bytes]) == "SELECT q'[?]' FROM dual WHERE a = :1")
        #expect(substituted("SELECT Q'{?}', q'(?)', q'<?>', q'!?!' FROM dual WHERE a = ?", [Self.bytes])
            == "SELECT Q'{?}', q'(?)', q'<?>', q'!?!' FROM dual WHERE a = :1")
        #expect(substituted("SELECT nq'[?]', Nq'[?]' FROM dual WHERE a = ?", [Self.bytes])
            == "SELECT nq'[?]', Nq'[?]' FROM dual WHERE a = :1")
    }

    /// Read as a plain literal, `q'[it's]'` would close at `it'` and swallow the placeholder after it.
    @Test("An alternative-quoted literal takes no escapes, so a quote inside it does not end it")
    func alternativeQuoteHoldsAQuote() {
        #expect(substituted("SELECT q'[it's]' FROM dual WHERE a = ?", [.text("v")])
            == "SELECT q'[it's]' FROM dual WHERE a = 'v'")
    }

    @Test("A question mark in a quoted name is part of the name")
    func quotedIdentifier() {
        #expect(substituted("UPDATE \"T\" SET \"Paid?\" = ? WHERE \"A?\"\"b\" = ?", [Self.bytes, .text("k")])
            == "UPDATE \"T\" SET \"Paid?\" = :1 WHERE \"A?\"\"b\" = 'k'")
    }

    @Test("A question mark in a comment is text")
    func comments() {
        #expect(substituted("SELECT 1 -- why?\nFROM dual WHERE a = ?", [.text("5")]) == "SELECT 1 -- why?\nFROM dual WHERE a = 5")
        #expect(substituted("SELECT /* ? */ 1 FROM dual WHERE a = ?", [.null]) == "SELECT /* ? */ 1 FROM dual WHERE a = NULL")
    }

    @Test("A replaced placeholder glued to a word is kept apart from it")
    func gluedPlaceholder() {
        #expect(substituted("WHERE a=?and b=?", [.text("1"), Self.bytes]) == "WHERE a=1 and b=:1")
    }

    @Test("A placeholder with no parameter left stays as it is")
    func missingParameter() {
        let statement = OracleBindPlaceholders.substituting("WHERE a = ? AND b = ?", parameters: [Self.bytes])
        #expect(statement.sql == "WHERE a = :1 AND b = ?")
        #expect(statement.binds == [Self.bytes])
    }

    @Test("Text outside the BMP survives the rewrite")
    func nonBMPText() {
        #expect(substituted("SELECT '👍🏽?' FROM dual WHERE a = ? AND b = '🇻🇳'", [.text("🇻🇳")])
            == "SELECT '👍🏽?' FROM dual WHERE a = '🇻🇳' AND b = '🇻🇳'")
    }

    @Test("A statement with no placeholder comes back unchanged")
    func noPlaceholder() {
        let statement = OracleBindPlaceholders.substituting("SELECT * FROM \"T\"", parameters: [.text("unused")])
        #expect(statement.sql == "SELECT * FROM \"T\"")
        #expect(statement.binds.isEmpty)
    }
}
