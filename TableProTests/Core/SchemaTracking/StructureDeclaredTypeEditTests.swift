//
//  StructureDeclaredTypeEditTests.swift
//  TableProTests
//
//  Editing a column whose type is read as the server declares it. PostgreSQLDriverTests holds
//  PostgreSQLColumnClauses to writing the type from what these hand over.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct StructureDeclaredTypeEditTests {
    @MainActor private func loadedManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(
                    name: "code",
                    dataType: "character varying(50)",
                    isNullable: true,
                    isPrimaryKey: false,
                    ddlSpelling: "character varying(50)"
                ),
                ColumnInfo(
                    name: "status",
                    dataType: "status",
                    isNullable: false,
                    isPrimaryKey: false,
                    allowedValues: ["new", "paid"],
                    ddlSpelling: "public.status",
                    classificationTypeName: "ENUM"
                )
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: []
        )
        return manager
    }

    @Test("A column loaded and left alone has nothing to save")
    @MainActor func untouchedColumnIsNoChange() {
        let manager = loadedManager()
        #expect(manager.workingColumns.map(\.dataType) == ["character varying(50)", "status"])
        #expect(manager.workingColumns[1].typeNameForClassification == "ENUM")
        #expect(!manager.hasChanges)
    }

    @Test("A retyped column is staged with what was typed, and the catalog's spellings retire")
    @MainActor func retypedColumnCarriesTheTypedValue() throws {
        let manager = loadedManager()
        let loaded = manager.workingColumns[0]
        var retyped = loaded
        retyped.dataType = "varchar(80)"
        manager.updateColumn(id: loaded.id, with: retyped)

        #expect(manager.hasChanges)
        let staged = manager.workingColumns[0]
        #expect(staged.dataType == "varchar(80)")
        #expect(staged.ddlSpelling == nil)
        #expect(staged.typeNameForClassification == "varchar(80)")
        let written = staged.toPlugin()
        #expect(written.dataType == "varchar(80)")
        #expect(written.ddlSpelling == nil)
        #expect(written.ddlCollation == nil)
    }

    @Test("An enum column left alone writes its qualified spelling, and a retype writes the typed one")
    @MainActor func enumColumnKeepsItsQualifiedSpellingUntilItIsEdited() {
        let manager = loadedManager()
        let loaded = manager.workingColumns[1]
        #expect(loaded.toPlugin().ddlSpelling == "public.status")

        var retyped = loaded
        retyped.dataType = "text"
        manager.updateColumn(id: loaded.id, with: retyped)
        let written = manager.workingColumns[1].toPlugin()
        #expect(written.dataType == "text")
        #expect(written.ddlSpelling == nil)
        #expect(written.ddlCollation == nil)
    }
}
