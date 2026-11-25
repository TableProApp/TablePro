//
//  StructureSectionColumnVisibilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Hide Column and Show All Columns reach a section through `model.actions`, as the header menu sends them.
@MainActor
struct StructureSectionColumnVisibilityTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeEditor() -> StructureDefinitionEditor {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true),
                ColumnInfo(name: "total", dataType: "DECIMAL(10,2)", isNullable: true, isPrimaryKey: false),
            ],
            indexes: [IndexInfo(name: "ix_total", columns: ["total"], isUnique: false, isPrimary: false, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .existingTable(
                connection: TestFixtures.makeConnection(database: "shop", type: .mysql),
                databaseName: "shop",
                schemaName: nil,
                tableName: "orders",
                objectKind: .table,
                isSessionBound: false
            ),
            defaults: suite.defaults
        )
        editor.refresh()
        return editor
    }

    @Test("Show All Columns brings back the fields the Columns section starts with hidden")
    func showAllColumnsRevealsTheDefaultHiddenFields() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        let collation = StructureColumnField.collation.displayName
        #expect(!adapter.model.columns.orderedNames.contains(collation))

        adapter.model.actions?.gridShowAllColumns()

        #expect(adapter.model.columns.orderedNames.contains(collation))
        #expect(adapter.model.columns.count == adapter.model.rows.columns.count)
        #expect(StructureGridStateStore(section: .columns, defaults: suite.defaults).columnLayout.hiddenColumns.isEmpty)
    }

    @Test("Hide Column takes the column out of the section's grid and keeps it hidden for the next table")
    func hideColumnHidesAndPersists() throws {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .indexes)
        let column = try #require(adapter.model.columns.column(at: 0))

        adapter.model.actions?.gridHideColumn(column)

        #expect(adapter.model.columns.column(id: column.id) == nil)
        #expect(StructureGridStateStore(section: .indexes, defaults: suite.defaults).columnLayout.hiddenColumns == [column.name])
    }

    @Test("The last shown column stays, so the header still offers Show All Columns")
    func lastShownColumnCannotBeHidden() throws {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .indexes)
        let names = adapter.model.rows.columns
        adapter.model.updateColumnLayout { $0.hiddenColumns = Set(names.dropFirst()) }
        let last = try #require(adapter.model.columns.column(at: 0))
        #expect(adapter.model.columns.count == 1)

        adapter.model.actions?.gridHideColumn(last)

        #expect(adapter.model.columns.orderedNames == [last.name])
    }
}
