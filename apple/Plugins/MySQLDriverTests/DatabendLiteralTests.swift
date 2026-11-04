//
//  DatabendLiteralTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct DatabendLiteralTests {
    @Test("A string literal escapes the characters Databend interprets")
    func escapesInterpretedCharacters() {
        #expect(DatabendLiteral.quoted("it's") == "'it''s'")
        #expect(DatabendLiteral.quoted("C:\\temp\\") == "'C:\\\\temp\\\\'")
        #expect(DatabendLiteral.quoted("a\nb\tc\rd") == "'a\\nb\\tc\\rd'")
        #expect(DatabendLiteral.quoted("a\0b") == "'a\\x00b'")
    }

    // Measured on 1.2.880 and 1.2.958: '\071f3ac2' reads as 9f3ac2, and '\x0071f3ac2' as NUL then 71f3ac2.
    @Test("NUL before an octal digit stays NUL, not the start of an octal escape")
    func nulBeforeOctalDigit() {
        #expect(DatabendLiteral.quoted("\u{0}71f3ac2") == "'\\x0071f3ac2'")
        #expect(databendStringValue(of: DatabendLiteral.quoted("\u{0}71f3ac2")) == "\u{0}71f3ac2")
    }

    @Test("Databend reads every written literal back as the value, as one token")
    func literalRoundTrip() throws {
        for value in databendHostileValues(count: 600, seed: 0xDA7A_BE01) {
            let sql = try DatabendLiteral.inline("SELECT ?", parameters: [.text(value)])
            let literal = String(sql.dropFirst("SELECT ".count))
            #expect(databendStringValue(of: literal) == value, "\(literal.debugDescription)")
        }
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

    // Measured on 1.2.880: `/** c **/ SELECT 1 WHERE 'a' = '*/ SELECT 2 --'` returned 2.
    @Test("A placeholder that an older Databend reads inside a comment is refused", arguments: [
        "/** customers of one region **/\nSELECT id FROM customers WHERE region = ?",
        "/**/ SELECT id FROM customers WHERE region = ?",
        "/* note **/ SELECT id FROM customers WHERE region = ?",
        "/** a **/ SELECT ? /* b */",
    ])
    func refusesPlaceholderBehindAPairedStarComment(sql: String) {
        #expect(throws: DatabendLiteralError.placeholdersDependOnServerVersion) {
            try DatabendLiteral.inline(sql, parameters: [.text("*/ DROP TABLE customers --")])
        }
    }

    @Test("A comment every release ends in the same place still binds", arguments: [
        "/* note */ SELECT ?", "/***/ SELECT ?", "/** note */ SELECT ?", "SELECT ? /** trailing",
    ])
    func bindsBehindAnUnambiguousComment(sql: String) throws {
        let bound = try DatabendLiteral.inline(sql, parameters: [.text("*/ x")])
        #expect(bound.contains("'*/ x'"))
    }

    @Test("A form feed ends a line comment, so the placeholder after it is bound")
    func formFeedEndsLineComment() throws {
        let sql = try DatabendLiteral.inline("SELECT 1 --x\u{0C}, ?", parameters: [.text("v")])
        #expect(sql == "SELECT 1 --x\u{0C}, 'v'")
    }

    // Measured on 1.2.880 and 1.2.958: `/*+ ' */ SELECT 1 -- ' */ SELECT 2` returned 2.
    @Test("A hint's body is tokens, so a quote in it hides the placeholder after the hint")
    func hintBodyIsTokens() throws {
        #expect(throws: DatabendLiteralError.parameterCountMismatch(placeholders: 0, values: 1)) {
            try DatabendLiteral.inline("/*+ ' */ SELECT ? -- ' */ SELECT 2", parameters: [.text("v")])
        }
        let sql = try DatabendLiteral.inline("SELECT /*+ SET_VAR(a=1) */ * FROM t WHERE c = ?", parameters: [.text("v")])
        #expect(sql == "SELECT /*+ SET_VAR(a=1) */ * FROM t WHERE c = 'v'")
        let skipped = try DatabendLiteral.inline("/*+ ? ~*/ */ SELECT ?", parameters: [.text("v")])
        #expect(skipped == "/*+ ? ~*/ */ SELECT 'v'")
        let taken = try DatabendLiteral.inline("/*+ SELECT /*+ x */ SELECT ?", parameters: [.text("v")])
        #expect(taken == "/*+ SELECT /*+ x */ SELECT 'v'")
        #expect(throws: DatabendLiteralError.placeholdersDependOnServerVersion) {
            try DatabendLiteral.inline("MERGE /*+ SET_VAR(a=?) */ INTO t USING s ON t.id = s.id", parameters: [.text("v")])
        }
    }

    // Measured on 1.2.880 and 1.2.958: `a$$` is one name, and `$$` after a number opens a code string.
    @Test("A `$$` opens a code string only where it does not continue a name")
    func dollarQuotesFollowTokens() throws {
        #expect(throws: DatabendLiteralError.parameterCountMismatch(placeholders: 0, values: 1)) {
            try DatabendLiteral.inline("SELECT 1 AS a$$ /* $$ ? */", parameters: [.text("v")])
        }
        #expect(throws: DatabendLiteralError.parameterCountMismatch(placeholders: 0, values: 1)) {
            try DatabendLiteral.inline("SELECT 1 AS \u{E9}$$ /* $$ ? */", parameters: [.text("v")])
        }
        let afterNumber = try DatabendLiteral.inline("SELECT 1e5$$ ? $$, ?", parameters: [.text("v")])
        #expect(afterNumber == "SELECT 1e5$$ ? $$, 'v'")
        let afterPosition = try DatabendLiteral.inline("SELECT $1$$ ? $$, ?", parameters: [.text("v")])
        #expect(afterPosition == "SELECT $1$$ ? $$, 'v'")
    }

    @Test("A stage name keeps a quote after a backslash, so the placeholder in it is not bound")
    func stageNameHoldsItsPlaceholder() throws {
        #expect(throws: DatabendLiteralError.parameterCountMismatch(placeholders: 0, values: 1)) {
            try DatabendLiteral.inline("COPY INTO t FROM @s\\?", parameters: [.text("v")])
        }
        let sql = try DatabendLiteral.inline("SELECT * FROM @s WHERE x = ?", parameters: [.text("v")])
        #expect(sql == "SELECT * FROM @s WHERE x = 'v'")
        #expect(throws: DatabendLiteralError.placeholdersDependOnServerVersion) {
            try DatabendLiteral.inline("SELECT * FROM @s,? ", parameters: [.text("v")])
        }
    }

    @Test("An operator never splits into a comment opener the server does not read")
    func operatorsStayWhole() throws {
        #expect(throws: DatabendLiteralError.parameterCountMismatch(placeholders: 0, values: 1)) {
            try DatabendLiteral.inline("SELECT 2 */* ' */ ? '", parameters: [.text("v")])
        }
        let sql = try DatabendLiteral.inline("SELECT 4 //* ?", parameters: [.text("v")])
        #expect(sql == "SELECT 4 //* 'v'")
        #expect(throws: DatabendLiteralError.placeholdersDependOnServerVersion) {
            try DatabendLiteral.inline("SELECT a !*/* ? */", parameters: [.text("v")])
        }
        let json = try DatabendLiteral.inline("SELECT j ?| ['a'] FROM t WHERE id = ?", parameters: [.text("v")])
        #expect(json == "SELECT j ?| ['a'] FROM t WHERE id = 'v'")
    }

    @Test("A server older than the tokenizer rules the binder reads is refused, and an unread banner is not")
    func refusesAServerTooOldToBind() throws {
        #expect(throws: DatabendLiteralError.serverTooOldToBind) {
            try DatabendLiteral.inline("SELECT ?", parameters: [.text("v")], serverVersion: "8.0.90-v1.2.100-nightly")
        }
        let current = try DatabendLiteral.inline(
            "SELECT ?", parameters: [.text("v")], serverVersion: "8.0.90-v1.2.473-nightly-a1b2c3(rust-1.78.0)"
        )
        #expect(current == "SELECT 'v'")
        #expect(try DatabendLiteral.inline("SELECT ?", parameters: [.text("v")], serverVersion: "8.0.90") == "SELECT 'v'")
        let release = try #require(DatabendLiteral.release(fromServerVersion: "8.0.90-v1.2.925-patch-15(rust)"))
        #expect(release.major == 1 && release.minor == 2 && release.patch == 925)
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

struct StarRocksLiteralTests {
    @Test("StarRocks keeps MySQL's NUL escape, which reads no octal")
    func nulStaysMySQLStyle() throws {
        #expect(StarRocksLiteral.quoted("a\u{0}71") == "'a\\071'")
        #expect(try StarRocksLiteral.inline("SELECT ?", parameters: [.text("x")]) == "SELECT 'x'")
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

private func databendHostileValues(count: Int, seed: UInt64) -> [String] {
    let scalars: [Unicode.Scalar] = [
        "\0", "0", "7", "8", "x", "u", "\\", "'", "\"", "`", "\n", "\r", "\t", "\u{08}", "\u{0C}", "\u{1A}", "*", "/",
        "$", "?", "-", "a", "\u{E9}", "\u{1F600}",
    ]
    var generator = SplitMix64(seed: seed)
    return (0..<count).map { _ in
        var value = String.UnicodeScalarView()
        for _ in 0..<Int.random(in: 1...12, using: &generator) {
            value.append(scalars.randomElement(using: &generator) ?? "a")
        }
        return String(value)
    }
}

// What Databend reads from a whole single-quoted literal, or nil when it is not exactly one string token: the
// token.rs rule `'([^'\\]|\\.|'')*'` and QuotedString::from_str in src/query/ast/src/ast/quote.rs.
private func databendStringValue(of literal: String) -> String? {
    let scalars = Array(literal.unicodeScalars)
    guard scalars.count >= 2, scalars.first == "'" else { return nil }
    var index = 1
    var value = String.UnicodeScalarView()
    while index < scalars.count {
        let scalar = scalars[index]
        if scalar == "'" {
            if index + 1 < scalars.count, scalars[index + 1] == "'" {
                value.append("'")
                index += 2
                continue
            }
            return index == scalars.count - 1 ? String(value) : nil
        }
        guard scalar == "\\" else {
            value.append(scalar)
            index += 1
            continue
        }
        guard index + 1 < scalars.count, scalars[index + 1] != "\n" else { return nil }
        let escaped = scalars[index + 1]
        index += 2
        switch escaped {
        case "b": value.append("\u{08}")
        case "f": value.append("\u{0C}")
        case "n": value.append("\n")
        case "r": value.append("\r")
        case "t": value.append("\t")
        case "'", "\"", "\\": value.append(escaped)
        case "x":
            guard index + 2 <= scalars.count,
                  let byte = UInt8(String(String.UnicodeScalarView(scalars[index..<(index + 2)])), radix: 16)
            else { return nil }
            value.append(Unicode.Scalar(byte))
            index += 2
        case "0"..."7":
            var code = escaped.value - 48
            while index < scalars.count, ("0"..."7").contains(scalars[index]) {
                code = code * 8 + scalars[index].value - 48
                index += 1
            }
            guard let decoded = Unicode.Scalar(code) else { return nil }
            value.append(decoded)
        default:
            value.append("\\")
            value.append(escaped)
        }
    }
    return nil
}

