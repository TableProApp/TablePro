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

    @Test("Inserting a new column shifts position but the existing identifier still resolves")
    func identifiersFollowColumnsAcrossInsert() {
        let before = ColumnIdentitySchema(columns: ["id", "name", "email"])
        let after = ColumnIdentitySchema(columns: ["id", "created_at", "name", "email"])

        let nameId = NSUserInterfaceItemIdentifier("name")
        #expect(before.dataIndex(from: nameId) == 1)
        #expect(after.dataIndex(from: nameId) == 2)

        let emailId = NSUserInterfaceItemIdentifier("email")
        #expect(before.dataIndex(from: emailId) == 2)
        #expect(after.dataIndex(from: emailId) == 3)
    }

    @Test("Reordering columns reassigns indices but identifiers track the column")
    func identifiersFollowColumnsAcrossReorder() {
        let before = ColumnIdentitySchema(columns: ["id", "name", "email"])
        let after = ColumnIdentitySchema(columns: ["email", "id", "name"])

        for column in ["id", "name", "email"] {
            let id = NSUserInterfaceItemIdentifier(column)
            let beforeIndex = before.dataIndex(from: id)
            let afterIndex = after.dataIndex(from: id)
            #expect(beforeIndex != nil)
            #expect(afterIndex != nil)
            #expect(beforeIndex != afterIndex)
        }
    }

    @Test("Removing a column drops its identifier and keeps the others")
    func identifiersDropOnColumnRemoval() {
        let before = ColumnIdentitySchema(columns: ["id", "name", "email"])
        let after = ColumnIdentitySchema(columns: ["id", "email"])

        #expect(after.dataIndex(from: NSUserInterfaceItemIdentifier("name")) == nil)
        #expect(before.dataIndex(from: NSUserInterfaceItemIdentifier("email")) == 2)
        #expect(after.dataIndex(from: NSUserInterfaceItemIdentifier("email")) == 1)
    }

    @Test("A column literally named col_0 stays name-based and resolves to its own index")
    func literalColZeroColumnNameRoundTrips() {
        let schema = ColumnIdentitySchema(columns: ["id", "name", "col_0"])
        #expect(schema.isNameBased == true)

        let identifier = schema.identifier(for: 2)
        #expect(identifier?.rawValue == "col_0")
        #expect(schema.dataIndex(from: NSUserInterfaceItemIdentifier("col_0")) == 2)
        #expect(schema.dataIndex(from: NSUserInterfaceItemIdentifier("id")) == 0)
    }

    @Test("A literal col_0 column survives reordering without colliding with positional ids")
    func literalColZeroSurvivesReorder() {
        let before = ColumnIdentitySchema(columns: ["id", "name", "col_0"])
        let after = ColumnIdentitySchema(columns: ["col_0", "id", "name"])

        #expect(before.isNameBased == true)
        #expect(after.isNameBased == true)

        let columnId = NSUserInterfaceItemIdentifier("col_0")
        #expect(before.dataIndex(from: columnId) == 2)
        #expect(after.dataIndex(from: columnId) == 0)
    }
}
