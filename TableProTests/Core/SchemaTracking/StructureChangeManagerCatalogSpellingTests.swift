//
//  StructureChangeManagerCatalogSpellingTests.swift
//  TableProTests
//
//  A column read with the server's own DDL spellings, edited in the structure editor.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct StructureChangeManagerCatalogSpellingTests {
    @MainActor private func loadedManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        let columns = [
            ColumnInfo(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true, ddlSpelling: "integer"),
            ColumnInfo(
                name: "status",
                dataType: "ENUM",
                isNullable: false,
                isPrimaryKey: false,
                defaultValue: "'new'::status",
                allowedValues: ["new", "paid"],
                ddlSpelling: "public.status",
                ddlDefault: "'new'::public.status"
            )
        ]
        manager.loadSchema(
            tableName: "orders",
            columns: columns,
            indexes: [IndexInfo(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        return manager
    }

    @Test("Changing a type and changing it back leaves nothing to save")
    @MainActor func typeEditedAwayAndBackIsNoChange() {
        let manager = loadedManager()
        let loaded = manager.workingColumns[1]

        var retyped = loaded
        retyped.dataType = "TEXT"
        manager.updateColumn(id: loaded.id, with: retyped)
        #expect(manager.hasChanges)

        var restored = manager.workingColumns[1]
        restored.dataType = "ENUM"
        manager.updateColumn(id: loaded.id, with: restored)
        #expect(!manager.hasChanges)
        #expect(manager.workingColumns[1].ddlSpelling == "public.status")
    }

    @Test("Changing a default and changing it back leaves nothing to save")
    @MainActor func defaultEditedAwayAndBackIsNoChange() {
        let manager = loadedManager()
        let loaded = manager.workingColumns[1]

        var redefaulted = loaded
        redefaulted.defaultValue = "'paid'::status"
        manager.updateColumn(id: loaded.id, with: redefaulted)
        #expect(manager.hasChanges)
        #expect(manager.workingColumns[1].ddlDefault == nil)

        var restored = manager.workingColumns[1]
        restored.defaultValue = "'new'::status"
        manager.updateColumn(id: loaded.id, with: restored)
        #expect(!manager.hasChanges)
        #expect(manager.workingColumns[1].ddlDefault == "'new'::public.status")
    }
}
