//
//  ColumnIdentitySchemaTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("ColumnIdentitySchema")
@MainActor
struct ColumnIdentitySchemaTests {
    @Test("Unique columns produce name-based identifiers")
    func nameBasedIdentifiers() {
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])
        #expect(schema.isNameBased)
        #expect(schema.identifier(for: 0)?.rawValue == "id")
        #expect(schema.identifier(for: 1)?.rawValue == "name")
        #expect(schema.identifier(for: 2)?.rawValue == "email")
    }

    @Test("Duplicate column names fall back to positional identifiers")
    func positionalFallbackForDuplicates() {
        let schema = ColumnIdentitySchema(columns: ["a", "b", "a"])
        #expect(!schema.isNameBased)
        #expect(schema.identifier(for: 0)?.rawValue == "col_0")
        #expect(schema.identifier(for: 1)?.rawValue == "col_1")
        #expect(schema.identifier(for: 2)?.rawValue == "col_2")
    }

    @Test("Reserved row-number identifier triggers positional fallback")
    func rowNumberCollisionFallback() {
        let schema = ColumnIdentitySchema(columns: ["__rowNumber__", "name"])
        #expect(!schema.isNameBased)
    }

    @Test("dataIndex round-trips for name-based schema")
    func roundTripNameBased() {
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])
        let identifier = NSUserInterfaceItemIdentifier("name")
        #expect(schema.dataIndex(from: identifier) == 1)
    }

    @Test("dataIndex round-trips for positional schema")
    func roundTripPositional() {
        let schema = ColumnIdentitySchema(columns: ["a", "b", "a"])
        #expect(schema.dataIndex(from: NSUserInterfaceItemIdentifier("col_2")) == 2)
    }

    @Test("Out-of-range identifier returns nil")
    func unknownIdentifier() {
        let schema = ColumnIdentitySchema(columns: ["id", "name"])
        #expect(schema.dataIndex(from: NSUserInterfaceItemIdentifier("missing")) == nil)
        #expect(schema.identifier(for: 99) == nil)
        #expect(schema.identifier(for: -1) == nil)
    }

    @Test("Row-number identifier is excluded from data index")
    func rowNumberIsNotDataColumn() {
        let schema = ColumnIdentitySchema(columns: ["id", "name"])
        #expect(schema.dataIndex(from: ColumnIdentitySchema.rowNumberIdentifier) == nil)
    }

    @Test("Empty schema is constructible and queryable")
    func emptySchema() {
        let schema = ColumnIdentitySchema.empty
        #expect(schema.identifiers.isEmpty)
        #expect(schema.isNameBased)
        #expect(schema.identifier(for: 0) == nil)
    }
}
