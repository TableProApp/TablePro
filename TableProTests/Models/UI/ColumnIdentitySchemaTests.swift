//
//  ColumnIdentitySchemaTests.swift
//  TableProTests
//

import AppKit
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ColumnIdentitySchema")
@MainActor
struct ColumnIdentitySchemaTests {
    @Test("Identifiers are slot-based regardless of column names")
    func slotBasedIdentifiers() {
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])
        #expect(schema.identifier(for: 0)?.rawValue == "dataColumn-0")
        #expect(schema.identifier(for: 1)?.rawValue == "dataColumn-1")
        #expect(schema.identifier(for: 2)?.rawValue == "dataColumn-2")
    }

    @Test("Duplicate column names produce unique slot identifiers")
    func duplicateColumnNamesGetUniqueSlots() {
        let schema = ColumnIdentitySchema(columns: ["a", "b", "a"])
        #expect(schema.identifier(for: 0)?.rawValue == "dataColumn-0")
        #expect(schema.identifier(for: 1)?.rawValue == "dataColumn-1")
        #expect(schema.identifier(for: 2)?.rawValue == "dataColumn-2")
    }

    @Test("dataIndex round-trips for slot identifier")
    func roundTripDataIndex() {
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])
        let identifier = ColumnIdentitySchema.slotIdentifier(1)
        #expect(schema.dataIndex(from: identifier) == 1)
    }

    @Test("dataIndex returns nil for unknown identifier")
    func unknownIdentifierReturnsNil() {
        let schema = ColumnIdentitySchema(columns: ["id", "name"])
        #expect(schema.dataIndex(from: NSUserInterfaceItemIdentifier("missing")) == nil)
        #expect(schema.dataIndex(from: NSUserInterfaceItemIdentifier("dataColumn-99")) == nil)
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
        #expect(schema.columnNames.isEmpty)
        #expect(schema.identifier(for: 0) == nil)
    }

    @Test("columnName returns the name at the given slot")
    func columnNameForSlot() {
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])
        #expect(schema.columnName(for: 0) == "id")
        #expect(schema.columnName(for: 1) == "name")
        #expect(schema.columnName(for: 2) == "email")
        #expect(schema.columnName(for: 3) == nil)
        #expect(schema.columnName(for: -1) == nil)
    }

    @Test("dataIndex(forColumnName:) returns the slot for unique names")
    func dataIndexForColumnName() {
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])
        #expect(schema.dataIndex(forColumnName: "id") == 0)
        #expect(schema.dataIndex(forColumnName: "name") == 1)
        #expect(schema.dataIndex(forColumnName: "email") == 2)
        #expect(schema.dataIndex(forColumnName: "missing") == nil)
    }

    @Test("dataIndex(forColumnName:) returns the last slot for duplicate names")
    func dataIndexForDuplicateColumnNamePicksLast() {
        let schema = ColumnIdentitySchema(columns: ["a", "b", "a"])
        #expect(schema.dataIndex(forColumnName: "a") == 2)
        #expect(schema.dataIndex(forColumnName: "b") == 1)
    }

    @Test("Inserting a new column shifts subsequent slot identifiers")
    func insertingColumnShiftsSlots() {
        let after = ColumnIdentitySchema(columns: ["id", "created_at", "name", "email"])
        #expect(after.dataIndex(forColumnName: "name") == 2)
        #expect(after.dataIndex(forColumnName: "email") == 3)
    }

    @Test("Reordering columns reassigns slot identifiers")
    func reorderingReassignsSlots() {
        let before = ColumnIdentitySchema(columns: ["id", "name", "email"])
        let after = ColumnIdentitySchema(columns: ["email", "id", "name"])
        #expect(before.dataIndex(forColumnName: "email") == 2)
        #expect(after.dataIndex(forColumnName: "email") == 0)
    }

    @Test("Removing a column drops its slot")
    func removingColumnDropsSlot() {
        let after = ColumnIdentitySchema(columns: ["id", "email"])
        #expect(after.dataIndex(forColumnName: "name") == nil)
        #expect(after.dataIndex(forColumnName: "email") == 1)
    }

    @Test("Column literally named dataColumn-0 round-trips by name lookup")
    func literalDataColumnName() {
        let schema = ColumnIdentitySchema(columns: ["id", "name", "dataColumn-0"])
        #expect(schema.columnName(for: 2) == "dataColumn-0")
        #expect(schema.dataIndex(forColumnName: "dataColumn-0") == 2)
        #expect(schema.identifier(for: 2)?.rawValue == "dataColumn-2")
    }

    @Test("slotIdentifier static helper produces canonical raw value")
    func slotIdentifierStatic() {
        #expect(ColumnIdentitySchema.slotIdentifier(0).rawValue == "dataColumn-0")
        #expect(ColumnIdentitySchema.slotIdentifier(7).rawValue == "dataColumn-7")
    }

    @Test("Reserved row-number column name does not collide with slot identifiers")
    func reservedRowNumberNameDoesNotCollide() {
        let schema = ColumnIdentitySchema(columns: ["__rowNumber__", "name"])
        #expect(schema.identifier(for: 0)?.rawValue == "dataColumn-0")
        #expect(schema.dataIndex(from: ColumnIdentitySchema.rowNumberIdentifier) == nil)
        #expect(schema.dataIndex(forColumnName: "__rowNumber__") == 0)
    }

    @Test("Empty array column input has no identifiers")
    func emptyColumnsInput() {
        let schema = ColumnIdentitySchema(columns: [])
        #expect(schema.identifiers.isEmpty)
        #expect(schema.dataIndex(from: NSUserInterfaceItemIdentifier("anything")) == nil)
        #expect(schema.dataIndex(forColumnName: "anything") == nil)
    }
}
