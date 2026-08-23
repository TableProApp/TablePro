import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Dameng parameter binder")
struct DamengParameterBinderTests {
    @Test("binds text, null, and binary values")
    func bindsSupportedValues() throws {
        let sql = try DamengParameterBinder.bind(
            query: "INSERT INTO sample VALUES (?, ?, ?)",
            parameters: [.text("达梦 O'Brien"), .null, .bytes(Data([0x00, 0xAB, 0xFF]))],
            escaping: .backslashLiteral
        )
        #expect(sql == "INSERT INTO sample VALUES ('达梦 O''Brien', NULL, HEXTORAW('00ABFF'))")
    }

    @Test("does not bind placeholders inside SQL syntax regions")
    func preservesSyntaxRegions() throws {
        let sql = try DamengParameterBinder.bind(
            query: """
                SELECT '?', "?", q'[?]', ?
                FROM sample
                -- ?
                /* outer ? /* inner ? */ */
                """,
            parameters: [.text("bound")],
            escaping: .backslashLiteral
        )
        #expect(sql.contains("SELECT '?', \"?\", q'[?]', 'bound'"))
        #expect(sql.contains("-- ?"))
        #expect(sql.contains("/* outer ? /* inner ? */ */"))
    }

    @Test("escapes injection-shaped text as one literal")
    func escapesInjectionText() throws {
        let sql = try DamengParameterBinder.bind(
            query: "SELECT ? FROM DUAL",
            parameters: [.text("x'; DROP SCHEMA SYSDBA CASCADE; --")],
            escaping: .backslashLiteral
        )
        #expect(sql == "SELECT 'x''; DROP SCHEMA SYSDBA CASCADE; --' FROM DUAL")
    }

    @Test("rejects parameter count mismatches")
    func rejectsCountMismatches() {
        #expect(throws: DamengParameterBindingError.insufficientParameters) {
            try DamengParameterBinder.bind(
                query: "SELECT ?, ?", parameters: [.text("one")], escaping: .backslashLiteral
            )
        }
        #expect(throws: DamengParameterBindingError.unusedParameters) {
            try DamengParameterBinder.bind(
                query: "SELECT ?", parameters: [.text("one"), .text("two")], escaping: .backslashLiteral
            )
        }
    }

    @Test("rejects embedded null bytes")
    func rejectsEmbeddedNull() {
        #expect(throws: DamengParameterBindingError.embeddedNull) {
            try DamengParameterBinder.bind(
                query: "SELECT ?", parameters: [.text("a\0b")], escaping: .backslashLiteral
            )
        }
    }

    @Test("escapes backslashes when the server treats them as escapes")
    func escapesBackslashInEscapeMode() throws {
        let sql = try DamengParameterBinder.bind(
            query: "SELECT * FROM t WHERE a = ? AND b = ?",
            parameters: [.text("\\"), .text(" OR 1=1 -- ")],
            escaping: .backslashEscape
        )
        #expect(sql == "SELECT * FROM t WHERE a = '\\\\' AND b = ' OR 1=1 -- '")
    }

    @Test("keeps backslashes literal when the server does not escape them")
    func preservesBackslashInLiteralMode() throws {
        let sql = try DamengParameterBinder.bind(
            query: "SELECT ? FROM DUAL",
            parameters: [.text("C:\\temp")],
            escaping: .backslashLiteral
        )
        #expect(sql == "SELECT 'C:\\temp' FROM DUAL")
    }

    @Test("rejects backslashes when backslash handling is unknown")
    func rejectsBackslashWhenUnprobed() {
        #expect(throws: DamengParameterBindingError.unknownBackslashHandling) {
            try DamengParameterBinder.bind(
                query: "SELECT ?", parameters: [.text("a\\b")], escaping: .unknown
            )
        }
        #expect(throws: DamengParameterBindingError.unknownBackslashHandling) {
            try DamengParameterBinder.escapedText("a\\\u{0301}b", escaping: .unknown)
        }
        #expect(DamengParameterBindingError.unknownBackslashHandling.errorDescription?.isEmpty == false)
    }

    @Test("escapes a quote that carries a combining mark")
    func escapesQuoteWithCombiningMark() throws {
        let sql = try DamengParameterBinder.bind(
            query: "SELECT * FROM t WHERE a = ?",
            parameters: [.text("x'\u{0301} OR 1=1 -- ")],
            escaping: .backslashLiteral
        )
        #expect(sql == "SELECT * FROM t WHERE a = 'x''\u{0301} OR 1=1 -- '")
    }

    @Test("doubles a backslash that carries a combining mark in escape mode")
    func escapesBackslashWithCombiningMark() throws {
        let sql = try DamengParameterBinder.bind(
            query: "SELECT ?",
            parameters: [.text("a\\\u{0301}b")],
            escaping: .backslashEscape
        )
        #expect(sql == "SELECT 'a\\\\\u{0301}b'")
    }

    @Test("tracks an escaped quote inside a literal when backslashes escape")
    func tracksBackslashEscapedQuoteInsideLiterals() throws {
        let sql = try DamengParameterBinder.bind(
            query: "SELECT '\\'', ? FROM DUAL",
            parameters: [.text("bound")],
            escaping: .backslashEscape
        )
        #expect(sql == "SELECT '\\'', 'bound' FROM DUAL")
    }
}
