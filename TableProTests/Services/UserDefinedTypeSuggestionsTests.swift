//
//  UserDefinedTypeSuggestionsTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("User-defined type suggestions")
struct UserDefinedTypeSuggestionsTests {
    private func type(_ name: String, schema: String?, spelling: String? = nil) -> UserDefinedTypeInfo {
        UserDefinedTypeInfo(name: name, kind: .enumeration, schema: schema, columnTypeSpelling: spelling)
    }

    /// PostgreSQL searches `pg_catalog` ahead of the search path, so a bare `text` names the
    /// built-in even where the table's own schema holds a domain called `text`. Every
    /// schema-bound type is therefore qualified, the table's own schema included.
    @Test("Every schema-bound type is qualified, the table's own schema included")
    func qualifiesEverySchema() {
        let entries = UserDefinedTypeSuggestions.entries(
            types: [type("text", schema: "public"), type("status", schema: "sales")],
            tableSchema: "public"
        )
        #expect(entries == ["public.text", "sales.status"])
    }

    @Test("A type with no schema is offered bare")
    func bareWithoutSchema() {
        let entries = UserDefinedTypeSuggestions.entries(types: [type("plain", schema: nil)], tableSchema: nil)
        #expect(entries == ["plain"])
    }

    @Test("Entries sort case-insensitively so the picker reads as one list")
    func sortsCaseInsensitively() {
        let entries = UserDefinedTypeSuggestions.entries(
            types: [type("zeta", schema: "app"), type("alpha", schema: "app"), type("beta", schema: "app")],
            tableSchema: "app"
        )
        #expect(entries == ["app.alpha", "app.beta", "app.zeta"])
    }

    /// The engine knows which names it folds and which it reserves; its own spelling wins over
    /// anything the app could work out from the characters.
    @Test("The engine's own spelling is used when the driver supplied one")
    func prefersEngineSpelling() {
        let entries = UserDefinedTypeSuggestions.entries(
            types: [type("select", schema: "app", spelling: "app.\"select\""), type("mood", schema: "app", spelling: "app.mood")],
            tableSchema: "app"
        )
        #expect(entries == ["app.mood", "app.\"select\""])
    }

    /// Without an engine spelling, a name the server would fold to lower case, or refuse bare,
    /// arrives already quoted.
    @Test("The fallback quotes a name that is not a plain lower-case identifier, in each part")
    func quotesNamesThatNeedIt() {
        #expect(UserDefinedTypeSuggestions.identifier("mood") == "mood")
        #expect(UserDefinedTypeSuggestions.identifier("order_status2") == "order_status2")
        #expect(UserDefinedTypeSuggestions.identifier("Mood") == "\"Mood\"")
        #expect(UserDefinedTypeSuggestions.identifier("Weird Name") == "\"Weird Name\"")
        #expect(UserDefinedTypeSuggestions.identifier("2fast") == "\"2fast\"")
        #expect(UserDefinedTypeSuggestions.identifier("a\"b") == "\"a\"\"b\"")

        let entries = UserDefinedTypeSuggestions.entries(
            types: [type("Weird Name", schema: "My Schema"), type("mood", schema: "My Schema")],
            tableSchema: "public"
        )
        #expect(entries == ["\"My Schema\".mood", "\"My Schema\".\"Weird Name\""])
    }
}
