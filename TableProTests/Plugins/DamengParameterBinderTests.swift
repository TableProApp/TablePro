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
            parameters: [.text("达梦 O'Brien"), .null, .bytes(Data([0x00, 0xAB, 0xFF]))]
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
            parameters: [.text("bound")]
        )
        #expect(sql.contains("SELECT '?', \"?\", q'[?]', 'bound'"))
        #expect(sql.contains("-- ?"))
        #expect(sql.contains("/* outer ? /* inner ? */ */"))
    }

    @Test("escapes injection-shaped text as one literal")
    func escapesInjectionText() throws {
        let sql = try DamengParameterBinder.bind(
            query: "SELECT ? FROM DUAL",
            parameters: [.text("x'; DROP SCHEMA SYSDBA CASCADE; --")]
        )
        #expect(sql == "SELECT 'x''; DROP SCHEMA SYSDBA CASCADE; --' FROM DUAL")
    }

    @Test("rejects parameter count mismatches")
    func rejectsCountMismatches() {
        #expect(throws: DamengParameterBindingError.insufficientParameters) {
            try DamengParameterBinder.bind(query: "SELECT ?, ?", parameters: [.text("one")])
        }
        #expect(throws: DamengParameterBindingError.unusedParameters) {
            try DamengParameterBinder.bind(query: "SELECT ?", parameters: [.text("one"), .text("two")])
        }
    }

    @Test("rejects embedded null bytes")
    func rejectsEmbeddedNull() {
        #expect(throws: DamengParameterBindingError.embeddedNull) {
            try DamengParameterBinder.bind(query: "SELECT ?", parameters: [.text("a\0b")])
        }
    }
}
