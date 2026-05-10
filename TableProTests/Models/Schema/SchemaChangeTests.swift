//
//  SchemaChangeTests.swift
//  TablePro
//
//  Tests for SchemaChange operations
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Schema Change")
struct SchemaChangeTests {
    // MARK: - Helper Methods

    private func makeColumn(name: String, dataType: String, isNullable: Bool = true) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
        )
    }

    private func makeIndex(name: String) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(),
            name: name,
            columns: ["id"],
            type: .btree,
            isUnique: false,
            isPrimary: false,
            comment: nil
        )
    }

    private func makeForeignKey(name: String) -> EditableForeignKeyDefinition {
        EditableForeignKeyDefinition(
            id: UUID(),
            name: name,
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"],
            onDelete: .noAction,
            onUpdate: .noAction
        )
    }

    // MARK: - isDelete Tests

    @Test("isDelete returns true for deleteColumn")
    func isDeleteColumnTrue() {
        let change = SchemaChange.deleteColumn(makeColumn(name: "test", dataType: "INT"))
        #expect(change.isDelete == true)
    }

    @Test("isDelete returns true for deleteIndex")
    func isDeleteIndexTrue() {
        let change = SchemaChange.deleteIndex(makeIndex(name: "idx_test"))
        #expect(change.isDelete == true)
    }

    @Test("isDelete returns true for deleteForeignKey")
    func isDeleteForeignKeyTrue() {
        let change = SchemaChange.deleteForeignKey(makeForeignKey(name: "fk_test"))
        #expect(change.isDelete == true)
    }

    @Test("isDelete returns false for add operations")
    func isDeleteAddOperationsFalse() {
        let addColumn = SchemaChange.addColumn(makeColumn(name: "test", dataType: "INT"))
        let addIndex = SchemaChange.addIndex(makeIndex(name: "idx_test"))
        let addFK = SchemaChange.addForeignKey(makeForeignKey(name: "fk_test"))

        #expect(addColumn.isDelete == false)
        #expect(addIndex.isDelete == false)
        #expect(addFK.isDelete == false)
    }

    @Test("isDelete returns false for modify operations")
    func isDeleteModifyOperationsFalse() {
        let col = makeColumn(name: "test", dataType: "INT")
        let idx = makeIndex(name: "idx_test")
        let fk = makeForeignKey(name: "fk_test")

        let modifyColumn = SchemaChange.modifyColumn(old: col, new: col)
        let modifyIndex = SchemaChange.modifyIndex(old: idx, new: idx)
        let modifyFK = SchemaChange.modifyForeignKey(old: fk, new: fk)

        #expect(modifyColumn.isDelete == false)
        #expect(modifyIndex.isDelete == false)
        #expect(modifyFK.isDelete == false)
    }

    // MARK: - isDestructive Tests

    @Test("isDestructive returns true for delete operations")
    func isDestructiveDeleteTrue() {
        let deleteColumn = SchemaChange.deleteColumn(makeColumn(name: "test", dataType: "INT"))
        let deleteIndex = SchemaChange.deleteIndex(makeIndex(name: "idx_test"))
        let deleteFK = SchemaChange.deleteForeignKey(makeForeignKey(name: "fk_test"))

        #expect(deleteColumn.isDestructive == true)
        #expect(deleteIndex.isDestructive == true)
        #expect(deleteFK.isDestructive == true)
    }

    @Test("isDestructive returns true for modifyColumn")
    func isDestructiveModifyColumnTrue() {
        let old = makeColumn(name: "test", dataType: "INT")
        let new = makeColumn(name: "test", dataType: "VARCHAR")
        let change = SchemaChange.modifyColumn(old: old, new: new)
        #expect(change.isDestructive == true)
    }

    @Test("isDestructive returns true for modifyPrimaryKey")
    func isDestructiveModifyPrimaryKeyTrue() {
        let change = SchemaChange.modifyPrimaryKey(old: ["id"], new: ["uuid"])
        #expect(change.isDestructive == true)
    }

    @Test("isDestructive returns false for add operations")
    func isDestructiveAddOperationsFalse() {
        let addColumn = SchemaChange.addColumn(makeColumn(name: "test", dataType: "INT"))
        let addIndex = SchemaChange.addIndex(makeIndex(name: "idx_test"))
        let addFK = SchemaChange.addForeignKey(makeForeignKey(name: "fk_test"))

        #expect(addColumn.isDestructive == false)
        #expect(addIndex.isDestructive == false)
        #expect(addFK.isDestructive == false)
    }

    // MARK: - requiresDataMigration Tests

    @Test("requiresDataMigration returns true for modifyColumn with type change")
    func requiresDataMigrationModifyColumnTypeChange() {
        let old = makeColumn(name: "test", dataType: "INT")
        let new = makeColumn(name: "test", dataType: "VARCHAR")
        let change = SchemaChange.modifyColumn(old: old, new: new)
        #expect(change.requiresDataMigration == true)
    }

    @Test("requiresDataMigration returns false for modifyColumn with same type")
    func requiresDataMigrationModifyColumnSameType() {
        let old = makeColumn(name: "test", dataType: "INT")
        let new = makeColumn(name: "test_renamed", dataType: "INT")
        let change = SchemaChange.modifyColumn(old: old, new: new)
        #expect(change.requiresDataMigration == false)
    }

    @Test("requiresDataMigration returns true for modifyColumn nullable to notNull")
    func requiresDataMigrationNullableToNotNull() {
        let old = makeColumn(name: "test", dataType: "INT", isNullable: true)
        let new = makeColumn(name: "test", dataType: "INT", isNullable: false)
        let change = SchemaChange.modifyColumn(old: old, new: new)
        #expect(change.requiresDataMigration == true)
    }

    @Test("requiresDataMigration returns true for deleteColumn")
    func requiresDataMigrationDeleteColumn() {
        let change = SchemaChange.deleteColumn(makeColumn(name: "test", dataType: "INT"))
        #expect(change.requiresDataMigration == true)
    }

    @Test("requiresDataMigration returns true for modifyPrimaryKey")
    func requiresDataMigrationModifyPrimaryKey() {
        let change = SchemaChange.modifyPrimaryKey(old: ["id"], new: ["uuid"])
        #expect(change.requiresDataMigration == true)
    }

    @Test("requiresDataMigration returns false for addColumn")
    func requiresDataMigrationAddColumn() {
        let change = SchemaChange.addColumn(makeColumn(name: "test", dataType: "INT"))
        #expect(change.requiresDataMigration == false)
    }

    // MARK: - description Tests

    @Test("description contains column name for addColumn")
    func descriptionAddColumn() {
        let change = SchemaChange.addColumn(makeColumn(name: "test_column", dataType: "INT"))
        #expect(change.description.contains("test_column"))
        #expect(change.description.contains("Add column"))
    }

    @Test("description contains both old and new names for modifyColumn")
    func descriptionModifyColumn() {
        let old = makeColumn(name: "old_name", dataType: "INT")
        let new = makeColumn(name: "new_name", dataType: "INT")
        let change = SchemaChange.modifyColumn(old: old, new: new)
        #expect(change.description.contains("old_name"))
        #expect(change.description.contains("new_name"))
        #expect(change.description.contains("Modify column"))
    }

    @Test("description contains index name for deleteIndex")
    func descriptionDeleteIndex() {
        let change = SchemaChange.deleteIndex(makeIndex(name: "idx_test"))
        #expect(change.description.contains("idx_test"))
        #expect(change.description.contains("Delete index"))
    }

    @Test("description contains primary key columns for modifyPrimaryKey")
    func descriptionModifyPrimaryKey() {
        let change = SchemaChange.modifyPrimaryKey(old: ["id"], new: ["uuid", "tenant_id"])
        #expect(change.description.contains("id"))
        #expect(change.description.contains("uuid"))
        #expect(change.description.contains("tenant_id"))
        #expect(change.description.contains("primary key"))
    }
}
