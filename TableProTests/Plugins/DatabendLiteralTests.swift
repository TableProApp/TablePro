//
//  DatabendLiteralTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Databend literal inlining")
struct DatabendLiteralTests {
    @Test("A string literal escapes the characters Databend interprets")
    func escapesInterpretedCharacters() {
        #expect(DatabendLiteral.quoted("it's") == "'it''s'")
        #expect(DatabendLiteral.quoted("C:\\temp\\") == "'C:\\\\temp\\\\'")
        #expect(DatabendLiteral.quoted("a\nb\tc\rd") == "'a\\nb\\tc\\rd'")
        #expect(DatabendLiteral.quoted("a\0b") == "'a\\0b'")
    }

    @Test("Ctrl-Z stays a raw character, since Databend reads backslash-Z as two characters")
    func controlZStaysRaw() {
        #expect(DatabendLiteral.quoted("a\u{1A}b") == "'a\u{1A}b'")
    }

    @Test("Values become a quoted string, NULL, or a hex binary literal")
    func literalsByKind() {
        #expect(DatabendLiteral.literal(for: .null) == "NULL")
        #expect(DatabendLiteral.literal(for: .text("5")) == "'5'")
        #expect(DatabendLiteral.literal(for: .bytes(Data([0x61, 0x62, 0x0F]))) == "X'61620F'")
    }

    @Test("Each placeholder takes the next value in order")
    func replacesPlaceholdersInOrder() throws {
        let sql = try DatabendLiteral.inline(
            "UPDATE `t` SET `a` = ? WHERE `id` = ? AND `b` IS NULL",
            parameters: [.text("x"), .text("7")]
        )
        #expect(sql == "UPDATE `t` SET `a` = 'x' WHERE `id` = '7' AND `b` IS NULL")
    }

    @Test("A question mark inside a literal, identifier or comment is not a placeholder")
    func ignoresQuotedQuestionMarks() throws {
        let sql = try DatabendLiteral.inline(
            "SELECT '?', \"?\", `a?`, 'it\\'s?', $$?$$ -- ?\n/* ? */ FROM t WHERE c = ?",
            parameters: [.text("v")]
        )
        #expect(sql == "SELECT '?', \"?\", `a?`, 'it\\'s?', $$?$$ -- ?\n/* ? */ FROM t WHERE c = 'v'")
    }

    @Test("A value cannot end its literal and run as SQL")
    func valuesCannotBreakOut() throws {
        let sql = try DatabendLiteral.inline(
            "SELECT * FROM t WHERE name = ?",
            parameters: [.text("x' OR '1'='1'; DROP TABLE t; --\\")]
        )
        #expect(sql == "SELECT * FROM t WHERE name = 'x'' OR ''1''=''1''; DROP TABLE t; --\\\\'")
    }

    @Test("A backslash inside a double-quoted token never exposes a placeholder the server reads as text")
    func backslashInDoubleQuotesIsConservative() throws {
        let sql = try DatabendLiteral.inline(
            "SELECT \"a\\\"?\" AS label FROM numbers(3) WHERE number = ?",
            parameters: [.text("x\" AS label, 42 AS injected FROM numbers(1) --")]
        )
        #expect(sql.hasPrefix("SELECT \"a\\\"?\" AS label"))
        #expect(sql.hasSuffix("WHERE number = 'x\" AS label, 42 AS injected FROM numbers(1) --'"))
    }

    @Test("A placeholder count that does not match the values is refused")
    func refusesCountMismatch() {
        #expect(throws: DatabendLiteralError.parameterCountMismatch(placeholders: 2, values: 1)) {
            try DatabendLiteral.inline("SELECT ?, ?", parameters: [.text("a")])
        }
        #expect(throws: DatabendLiteralError.parameterCountMismatch(placeholders: 0, values: 1)) {
            try DatabendLiteral.inline("SELECT 1", parameters: [.text("a")])
        }
    }
}

@Suite("Databend result shape")
struct DatabendResultShapeTests {
    @Test("A BOOLEAN arrives as a one-character SMALLINT, which no integer type shares")
    func booleanWireShape() {
        #expect(DatabendResultShape.isBoolean(typeRaw: 2, length: 1))
        #expect(!DatabendResultShape.isBoolean(typeRaw: 2, length: 5))
        #expect(!DatabendResultShape.isBoolean(typeRaw: 1, length: 1))
    }

    @Test("Booleans read as words Databend accepts back in a write")
    func booleanText() {
        #expect(DatabendResultShape.booleanText(fromWireText: "1") == "true")
        #expect(DatabendResultShape.booleanText(fromWireText: "0") == "false")
    }

    @Test("BINARY arrives as hex text and is decoded to its bytes")
    func binaryDecoding() {
        #expect(DatabendResultShape.binaryValue(fromWireText: Data("6162".utf8)) == Data("ab".utf8))
        #expect(DatabendResultShape.binaryValue(fromWireText: Data("0aFF".utf8)) == Data([0x0A, 0xFF]))
    }

    @Test("Text that is not hex is kept as it came")
    func binaryDecodingFallsBack() {
        #expect(DatabendResultShape.binaryValue(fromWireText: Data("abc".utf8)) == Data("abc".utf8))
        #expect(DatabendResultShape.binaryValue(fromWireText: Data("zz".utf8)) == Data("zz".utf8))
    }

    @Test("Databend answers a write with a one-row count, which becomes the affected rows")
    func affectedRowCount() {
        #expect(DatabendResultShape.affectedRowCount(
            columns: ["number of rows updated"], rows: [[.text("2")]]
        ) == 2)
        #expect(DatabendResultShape.affectedRowCount(
            columns: ["number of rows deleted"], rows: [[.text("0")]]
        ) == 0)
        #expect(DatabendResultShape.affectedRowCount(columns: ["id"], rows: [[.text("2")]]) == nil)
        #expect(DatabendResultShape.affectedRowCount(
            columns: ["number of rows updated"], rows: [[.text("1")], [.text("1")]]
        ) == nil)
    }
}
