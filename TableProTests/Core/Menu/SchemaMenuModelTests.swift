//
//  SchemaMenuModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Schema menu model")
struct SchemaMenuModelTests {
    @Test("System schemas are separated from the ones a user works in")
    func splitsSystemSchemas() {
        let sections = SchemaMenuModel.sections(
            all: ["public", "information_schema", "sales", "pg_catalog"],
            system: ["information_schema", "pg_catalog"]
        )

        #expect(sections.user == ["public", "sales"])
        #expect(sections.system == ["information_schema", "pg_catalog"])
    }

    /// Server order is meaningful on engines with a search path: the first schema is the one an
    /// unqualified name actually resolves to.
    @Test("Server order is preserved rather than sorted")
    func keepsServerOrder() {
        let sections = SchemaMenuModel.sections(all: ["zeta", "alpha", "middle"], system: [])

        #expect(sections.user == ["zeta", "alpha", "middle"])
    }

    @Test("A connection with no schemas reports empty")
    func emptyWhenNothingToList() {
        #expect(SchemaMenuModel.sections(all: [], system: ["pg_catalog"]).isEmpty)
    }

    @Test("A list of nothing but system schemas is not empty")
    func systemOnlyIsNotEmpty() {
        let sections = SchemaMenuModel.sections(all: ["pg_catalog"], system: ["pg_catalog"])

        #expect(sections.isEmpty == false)
        #expect(sections.user.isEmpty)
    }

    @Test("Matching is exact, so a schema merely containing a system name stays a user schema")
    func matchingIsExact() {
        let sections = SchemaMenuModel.sections(
            all: ["pg_catalog_archive", "pg_catalog"],
            system: ["pg_catalog"]
        )

        #expect(sections.user == ["pg_catalog_archive"])
        #expect(sections.system == ["pg_catalog"])
    }
}
