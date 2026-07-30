//
//  StructureInspectorRowBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor @Suite("StructureInspectorRowBuilder")
struct StructureInspectorRowBuilderTests {
    private func loadedManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "users",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "email", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        return manager
    }

    private func provider(
        _ manager: StructureChangeManager,
        tab: StructureTab = .columns,
        filterText: String? = nil,
        sortDescriptor: StructureSortDescriptor? = nil
    ) -> StructureRowProvider {
        StructureRowProvider(
            changeManager: manager,
            tab: tab,
            databaseType: .mysql,
            additionalFields: [.primaryKey],
            filterText: filterText,
            sortDescriptor: sortDescriptor
        )
    }

    private func value(_ row: InspectorRow, named name: String) -> String? {
        row.fields.first { $0.name == name }?.value
    }

    @Test("Fields carry the structure row's own names and values")
    func fieldsComeFromTheStructureRow() throws {
        let manager = loadedManager()
        let row = try #require(StructureInspectorRowBuilder.row(
            atDisplayRow: 1,
            tab: .columns,
            provider: provider(manager),
            canEditSchema: true
        ))

        #expect(value(row, named: String(localized: "Name")) == "email")
        #expect(value(row, named: String(localized: "Type")) == "VARCHAR(255)")
        #expect(value(row, named: String(localized: "Nullable")) == "YES")
        #expect(row.isEditable)
    }

    @Test("A filtered grid resolves the display row to the right column")
    func filteredDisplayRowResolvesToSourceEntity() throws {
        let manager = loadedManager()
        let row = try #require(StructureInspectorRowBuilder.row(
            atDisplayRow: 0,
            tab: .columns,
            provider: provider(manager, filterText: "email"),
            canEditSchema: true
        ))

        #expect(value(row, named: String(localized: "Name")) == "email")
    }

    @Test("A sorted grid resolves the display row to the right column")
    func sortedDisplayRowResolvesToSourceEntity() throws {
        let manager = loadedManager()
        let row = try #require(StructureInspectorRowBuilder.row(
            atDisplayRow: 0,
            tab: .columns,
            provider: provider(manager, sortDescriptor: StructureSortDescriptor(column: 0, ascending: false)),
            canEditSchema: true
        ))

        #expect(value(row, named: String(localized: "Name")) == "id")
    }

    @Test("Flag fields offer the same YES and NO list the grid offers")
    func flagFieldsUseDropdownEditors() throws {
        let manager = loadedManager()
        let row = try #require(StructureInspectorRowBuilder.row(
            atDisplayRow: 0,
            tab: .columns,
            provider: provider(manager),
            canEditSchema: true
        ))

        let nullable = try #require(row.fields.first { $0.name == String(localized: "Nullable") })
        #expect(nullable.editor == .enumPicker(values: StructureRowProvider.booleanOptions))

        let type = try #require(row.fields.first { $0.name == String(localized: "Type") })
        #expect(type.editor == .typePicker)

        let name = try #require(row.fields.first { $0.name == String(localized: "Name") })
        #expect(name.editor == .schemaText)
    }

    @Test("An edited field is reported as modified")
    func editedFieldIsMarkedModified() throws {
        let manager = loadedManager()
        var column = manager.workingColumns[1]
        column.dataType = "TEXT"
        manager.updateColumn(id: column.id, with: column)

        let row = try #require(StructureInspectorRowBuilder.row(
            atDisplayRow: 1,
            tab: .columns,
            provider: provider(manager),
            canEditSchema: true
        ))

        let type = try #require(row.fields.first { $0.name == String(localized: "Type") })
        #expect(type.isModified)
        let name = try #require(row.fields.first { $0.name == String(localized: "Name") })
        #expect(!name.isModified)
    }

    @Test("A row pending deletion is read-only")
    func pendingDeleteRowIsReadOnly() throws {
        let manager = loadedManager()
        manager.deleteColumn(id: manager.workingColumns[1].id)

        let row = try #require(StructureInspectorRowBuilder.row(
            atDisplayRow: 1,
            tab: .columns,
            provider: provider(manager),
            canEditSchema: true
        ))

        #expect(!row.isEditable)
    }

    @Test("An engine without schema editing gets a read-only row")
    func withoutSchemaEditingRowIsReadOnly() throws {
        let manager = loadedManager()
        let row = try #require(StructureInspectorRowBuilder.row(
            atDisplayRow: 0,
            tab: .columns,
            provider: provider(manager),
            canEditSchema: false
        ))

        #expect(!row.isEditable)
    }

    @Test("Tabs without a row grid supply nothing", arguments: [StructureTab.ddl, .parts, .triggers])
    func nonGridTabsSupplyNothing(tab: StructureTab) {
        let manager = loadedManager()
        #expect(StructureInspectorRowBuilder.row(
            atDisplayRow: 0,
            tab: tab,
            provider: provider(manager, tab: tab),
            canEditSchema: true
        ) == nil)
    }

    @Test("A display row past the end supplies nothing")
    func outOfRangeDisplayRowSuppliesNothing() {
        let manager = loadedManager()
        #expect(StructureInspectorRowBuilder.row(
            atDisplayRow: 9,
            tab: .columns,
            provider: provider(manager),
            canEditSchema: true
        ) == nil)
    }
}
