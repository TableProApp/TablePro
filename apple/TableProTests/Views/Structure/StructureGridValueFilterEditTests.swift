//
//  StructureGridValueFilterEditTests.swift
//  TableProTests
//
//  D2: under the grid's value filter the Structure and Create Table grids mapped a display row to the wrong
//  definition. Every edit now names its row by RowID, which the section's adapter mints per definition.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureGridValueFilterEditTests {
    private let columnNames = ["id", "email", "created_at"]
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeEditor() -> StructureDefinitionEditor {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "users",
            columns: columnNames.map {
                ColumnInfo(name: $0, dataType: "VARCHAR(64)", isNullable: true, isPrimaryKey: false)
            },
            indexes: [],
            foreignKeys: [],
            primaryKey: []
        )
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .existingTable(
                connection: TestFixtures.makeConnection(database: "shop", type: .mysql),
                databaseName: "shop",
                schemaName: nil,
                tableName: "users",
                objectKind: .table,
                isSessionBound: false
            ),
            defaults: suite.defaults
        )
        editor.refresh()
        return editor
    }

    private func makeCreateTableEditor(_ manager: StructureChangeManager) -> StructureDefinitionEditor {
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .newTable(connection: TestFixtures.makeConnection(type: .postgresql), databaseName: "shop", schemaName: "public"),
            defaults: suite.defaults
        )
        editor.refresh()
        return editor
    }

    // Keeps only the rows whose Name is `value`.
    private func filterName(to value: String, on model: DataGridModel) throws {
        let name = try #require(model.columns.column(at: 0))
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: [value], includesNull: false), columnName: name.name, forColumn: name.dataIndex)
        model.setValueFilter(filter)
    }

    private func commitName(_ text: String, atDisplayRow row: Int, on model: DataGridModel) throws -> Bool {
        let rowID = try #require(model.rowID(at: row))
        let name = try #require(model.columns.column(at: 0))
        return model.commit([DataGridCellEdit(rowID: rowID, columnID: name.id, value: .enteredText(text))], actionName: "Edit Cell")
    }

    @Test("A Structure edit on the one row a value filter leaves lands on that column")
    func structureEditUnderFilter() throws {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        let model = adapter.model
        try filterName(to: "created_at", on: model)
        try #require(model.rowCount == 1)
        #expect(model.rowID(at: 0) == adapter.rowID(forEntity: editor.manager.workingColumns[2].id))

        #expect(try commitName("created_on", atDisplayRow: 0, on: model))

        #expect(editor.manager.workingColumns.map(\.name) == ["id", "email", "created_on"])
    }

    @Test("A Structure inspector edit under a value filter lands on the row the grid shows")
    func structureInspectorEditUnderFilter() throws {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        try filterName(to: "email", on: adapter.model)
        let shown = try #require(adapter.model.rowID(at: 0))
        let id = try #require(adapter.entityID(of: shown))
        let nameField = try #require(adapter.provider.orderedColumnFields.firstIndex(of: .name))

        #expect(editor.inspectorForm(for: .columns, id: id)?.name == "email")
        editor.commitInspectorField(section: .columns, id: id, field: nameField, value: "mail")

        #expect(editor.manager.workingColumns.map(\.name) == ["id", "mail", "created_at"])
    }

    @Test("A Structure delete under a value filter marks the column the grid shows")
    func structureDeleteUnderFilter() throws {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        try filterName(to: "email", on: adapter.model)
        let shown = try #require(adapter.model.rowID(at: 0))

        adapter.gridDeleteRows([shown])

        let manager = editor.manager
        #expect(manager.deleteInsertState(for: 1, tab: .columns).isDeleted)
        #expect(!manager.deleteInsertState(for: 0, tab: .columns).isDeleted)
        #expect(!manager.deleteInsertState(for: 2, tab: .columns).isDeleted)
    }

    @Test("A Structure edit under a sort and a value filter still lands on the row it names")
    func structureEditUnderSortAndFilter() throws {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        let model = adapter.model
        model.setSort(SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user))
        #expect(model.rows.rows.compactMap { $0.values.first?.asText } == ["created_at", "email", "id"])
        try filterName(to: "id", on: model)
        #expect(model.rowID(at: 0) == adapter.rowID(forEntity: editor.manager.workingColumns[0].id))

        #expect(try commitName("user_id", atDisplayRow: 0, on: model))

        #expect(editor.manager.workingColumns.map(\.name) == ["user_id", "email", "created_at"])
    }

    // A value filter rearranges the list, so the drag that moves a column is withdrawn (changed on purpose).
    @Test("A value filter withdraws the column move")
    func valueFilterWithdrawsTheColumnMove() throws {
        let editor = makeEditor()
        let model = editor.adapter(for: .columns).model
        try filterName(to: "email", on: model)

        #expect(!model.configuration.rowReorder.isEnabled)
        #expect(!model.configuration.commands.contains(.moveRows))
    }

    @Test("A Create Table edit on the one row a value filter leaves lands on that definition")
    func createTableEditUnderFilter() throws {
        let manager = StructureChangeManager()
        for name in columnNames {
            var column = EditableColumnDefinition.placeholder()
            column.name = name
            column.dataType = "TEXT"
            manager.addColumn(column)
        }
        let editor = makeCreateTableEditor(manager)
        let model = editor.adapter(for: .columns).model
        try filterName(to: "email", on: model)
        try #require(model.rowCount == 1)

        #expect(try commitName("contact", atDisplayRow: 0, on: model))

        #expect(manager.workingColumns.map(\.name) == ["id", "contact", "created_at"])
    }

    @Test("A Create Table delete under a value filter removes the definition the grid shows")
    func createTableDeleteUnderFilter() throws {
        let manager = StructureChangeManager()
        for name in columnNames {
            var column = EditableColumnDefinition.placeholder()
            column.name = name
            manager.addColumn(column)
        }
        let editor = makeCreateTableEditor(manager)
        let adapter = editor.adapter(for: .columns)
        try filterName(to: "created_at", on: adapter.model)

        let shown = try #require(adapter.model.rowID(at: 0))
        adapter.gridDeleteRows([shown])

        #expect(manager.workingColumns.map(\.name) == ["id", "email"])
    }
}
