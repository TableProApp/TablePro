//
//  QuickSwitcherOpenTableTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

/// Both the open tabs and the catalog entries resolve through the same initializer, so these
/// assertions are always about a pair: what a tab produces against what a table produces.
struct QuickSwitcherOpenTableTests {
    private func tab(_ schema: String?, _ name: String, browsing: String?) -> QuickSwitcherOpenTable {
        QuickSwitcherOpenTable(schema: schema, name: name, browsing: browsing)
    }

    @Test("Two schemas holding the same table name do not match")
    func differentSchemasDoNotMatch() {
        let open = tab("public", "users", browsing: "analytics")
        let candidate = tab("analytics", "users", browsing: "analytics")
        #expect(open != candidate)
    }

    @Test("The same schema and name match")
    func sameSchemaMatches() {
        #expect(tab("public", "users", browsing: "public") == tab("public", "users", browsing: "public"))
    }

    /// MySQL reports no schema for either side, so name alone still has to match or every table
    /// loses its Open badge on that driver.
    @Test("A driver that reports no schema still matches on name")
    func unqualifiedBothSidesMatch() {
        #expect(tab(nil, "users", browsing: nil) == tab(nil, "users", browsing: nil))
        #expect(tab(nil, "users", browsing: nil) != tab(nil, "orders", browsing: nil))
    }

    /// A tab opened without an explicit schema follows the browse cursor, the same rule
    /// `TabTableContext.resolvedDatabaseName(browsing:)` applies to databases. Resolving only one
    /// side would make an unqualified tab stop matching a qualified catalog entry.
    @Test("An unqualified side resolves against the browse schema")
    func unqualifiedResolvesAgainstBrowseSchema() {
        #expect(tab(nil, "users", browsing: "public") == tab("public", "users", browsing: "public"))
    }

    @Test("An unqualified tab does not match a table in another schema")
    func unqualifiedDoesNotMatchOtherSchema() {
        #expect(tab(nil, "users", browsing: "public") != tab("analytics", "users", browsing: "public"))
    }

    @Test("An empty schema string is treated as unqualified")
    func emptySchemaIsUnqualified() {
        #expect(tab("", "users", browsing: "public") == tab("public", "users", browsing: "public"))
        #expect(tab("", "users", browsing: "") == tab(nil, "users", browsing: nil))
    }

    @Test("Names still have to match")
    func namesMustMatch() {
        #expect(tab("public", "users", browsing: "public") != tab("public", "orders", browsing: "public"))
    }
}
