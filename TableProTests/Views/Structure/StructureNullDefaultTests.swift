//
//  StructureNullDefaultTests.swift
//  TableProTests
//
//  A nullable MySQL or MariaDB column reads back with a NULL default (#3058), so turning Nullable
//  off is the ordinary way to reach `NOT NULL DEFAULT NULL`, which both servers refuse with
//  ERROR 1067. The default has to go with the nullability.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureNullDefaultTests {
    private func column(default defaultValue: String?, isNullable: Bool = true) -> EditableColumnDefinition {
        var column = EditableColumnDefinition.placeholder()
        column.name = "Name"
        column.dataType = "VARCHAR(255)"
        column.isNullable = isNullable
        column.defaultValue = defaultValue
        return column
    }

    @Test("Turning Nullable off drops a NULL default", arguments: ["NULL", "null", " NULL "])
    func notNullDropsNullDefault(spelling: String) {
        var target = column(default: spelling)
        StructureEditingSupport.updateColumn(&target, at: 0, with: "NO", orderedFields: [.nullable])
        #expect(target.isNullable == false)
        #expect(target.defaultValue == nil)
    }

    @Test(
        "Turning Nullable off keeps every other default",
        arguments: ["'NULL'", "''", "'abc'", "0", "(NULL)", "CURRENT_TIMESTAMP"]
    )
    func notNullKeepsOtherDefaults(defaultValue: String) {
        var target = column(default: defaultValue)
        StructureEditingSupport.updateColumn(&target, at: 0, with: "NO", orderedFields: [.nullable])
        #expect(target.isNullable == false)
        #expect(target.defaultValue == defaultValue)
    }

    @Test("Turning Nullable on invents no default")
    func nullableInventsNoDefault() {
        var target = column(default: nil, isNullable: false)
        StructureEditingSupport.updateColumn(&target, at: 0, with: "YES", orderedFields: [.nullable])
        #expect(target.isNullable == true)
        #expect(target.defaultValue == nil)
    }

    @Test("Setting Primary Key drops a NULL default along with the nullability")
    func primaryKeyDropsNullDefault() {
        var target = column(default: "NULL")
        StructureEditingSupport.updateColumn(&target, at: 0, with: "YES", orderedFields: [.primaryKey])
        #expect(target.isPrimaryKey == true)
        #expect(target.isNullable == false)
        #expect(target.defaultValue == nil)
    }

    @Test("The MODIFY written after turning Nullable off carries no DEFAULT NULL")
    func modifyAfterNotNullIsAccepted() {
        var target = column(default: "NULL")
        StructureEditingSupport.updateColumn(&target, at: 0, with: "NO", orderedFields: [.nullable])
        #expect(mysqlColumnDefinitionSQL(target.toPlugin()) == "`Name` VARCHAR(255) NOT NULL")
    }

    private func loadedManager(nameIsNullable: Bool = true, nameDefault: String? = "NULL") -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "Event",
            columns: [
                ColumnInfo(name: "new_id", dataType: "INT", isNullable: false, isPrimaryKey: true),
                ColumnInfo(name: "Name", dataType: "VARCHAR(255)", isNullable: nameIsNullable, isPrimaryKey: false,
                           defaultValue: nameDefault)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["new_id"]
        )
        return manager
    }

    @Test("Picking NULL as the default of a NOT NULL column is refused before save")
    func nullDefaultOnNotNullColumnIsRefused() {
        let manager = loadedManager(nameIsNullable: false, nameDefault: nil)
        var edited = manager.workingColumns[1]
        StructureEditingSupport.updateColumn(&edited, at: 0, with: "NULL", orderedFields: [.defaultValue])
        manager.updateColumn(id: edited.id, with: edited)

        #expect(manager.validationErrors[.column(edited.id)] != nil)
        #expect(manager.canCommit == false)
    }

    @Test("Turning Nullable off and then picking NULL is refused, whichever comes first")
    func notNullThenNullDefaultIsRefused() {
        let manager = loadedManager(nameDefault: nil)
        var edited = manager.workingColumns[1]
        StructureEditingSupport.updateColumn(&edited, at: 0, with: "NO", orderedFields: [.nullable])
        StructureEditingSupport.updateColumn(&edited, at: 0, with: "NULL", orderedFields: [.defaultValue])
        manager.updateColumn(id: edited.id, with: edited)

        #expect(manager.validationErrors[.column(edited.id)] != nil)
        #expect(manager.canCommit == false)
    }

    /// SQLite and DuckDB accept `NOT NULL DEFAULT NULL`, so a table can already hold one. Only a
    /// column the user is changing is theirs to fix before an unrelated edit saves.
    @Test("An untouched NOT NULL column that already defaults to NULL does not block another edit")
    func untouchedNotNullNullDefaultDoesNotBlock() {
        let manager = loadedManager(nameIsNullable: false, nameDefault: "NULL")
        var other = manager.workingColumns[0]
        other.comment = "surrogate key"
        manager.updateColumn(id: other.id, with: other)

        #expect(manager.validationErrors.isEmpty)
        #expect(manager.canCommit)
    }

    @Test("Editing another field of a column that already had NOT NULL and a NULL default does not block")
    func editingExistingNotNullNullDefaultDoesNotBlock() {
        let manager = loadedManager(nameIsNullable: false, nameDefault: "NULL")
        var edited = manager.workingColumns[1]
        edited.comment = "shown on the invoice"
        manager.updateColumn(id: edited.id, with: edited)

        #expect(manager.validationErrors.isEmpty)
        #expect(manager.canCommit)
    }

    @Test("A nullable column with a NULL default saves")
    func nullableNullDefaultIsAccepted() {
        let manager = loadedManager(nameDefault: nil)
        var edited = manager.workingColumns[1]
        StructureEditingSupport.updateColumn(&edited, at: 0, with: "NULL", orderedFields: [.defaultValue])
        manager.updateColumn(id: edited.id, with: edited)

        #expect(manager.validationErrors.isEmpty)
        #expect(manager.canCommit)
    }

    @Test("Undo brings back the nullability and the NULL default together")
    func undoRestoresBoth() {
        let manager = loadedManager()
        var edited = manager.workingColumns[1]
        StructureEditingSupport.updateColumn(&edited, at: 0, with: "NO", orderedFields: [.nullable])
        manager.updateColumn(id: edited.id, with: edited)
        #expect(manager.workingColumns[1].isNullable == false)
        #expect(manager.workingColumns[1].defaultValue == nil)

        manager.undo()
        #expect(manager.workingColumns[1].isNullable == true)
        #expect(manager.workingColumns[1].defaultValue == "NULL")
        #expect(manager.hasChanges == false)
    }
}
