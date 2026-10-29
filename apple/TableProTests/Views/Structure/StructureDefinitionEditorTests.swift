//
//  StructureDefinitionEditorTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@MainActor
struct StructureDefinitionEditorTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeEditor(type: DatabaseType = .postgresql) -> StructureDefinitionEditor {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "customer_id", dataType: "INT", isNullable: false, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "status", dataType: "TEXT", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [IndexInfo(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .existingTable(
                connection: TestFixtures.makeConnection(type: type),
                databaseName: "shop",
                schemaName: "public",
                tableName: "orders",
                objectKind: .table,
                isSessionBound: false
            ),
            defaults: suite.defaults
        )
        editor.refresh()
        return editor
    }

    private func id(of name: String, in editor: StructureDefinitionEditor) -> UUID {
        editor.manager.workingColumns.first { $0.name == name }!.id
    }

    @Test("Nothing selected puts the table in the inspector")
    func startsOnTable() {
        #expect(makeEditor().inspectorTarget == .table)
    }

    @Test("Selecting a column names it for the inspector")
    func selectingColumnTargetsIt() {
        let editor = makeEditor()
        let status = id(of: "status", in: editor)
        editor.adapter(for: .columns).select(entity: status)

        #expect(editor.inspectorTarget == .entity(.columns, status))
        #expect(editor.focusedSection == .columns)
    }

    @Test("Selecting in one section clears the others")
    func selectionIsExclusiveAcrossSections() {
        let editor = makeEditor()
        editor.adapter(for: .columns).select(entity: id(of: "status", in: editor))
        let index = editor.manager.workingIndexes[0].id
        editor.adapter(for: .indexes).select(entity: index)

        #expect(editor.adapter(for: .columns).model.selection.isEmpty)
        #expect(editor.inspectorTarget == .entity(.indexes, index))
    }

    @Test("A row keeps its identity when a sort reorders the section")
    func rowIdentitySurvivesSort() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        let status = id(of: "status", in: editor)
        adapter.select(entity: status)

        adapter.sortDidChange(SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user))

        #expect(adapter.selectedEntityIDs == [status])
        #expect(editor.inspectorTarget == .entity(.columns, status))
    }

    @Test("Removing a new column above keeps the selection on the same definition")
    func rowIdentitySurvivesRemovalAbove() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        adapter.addRow()
        let added = editor.manager.workingColumns.last!.id
        let moved = editor.manager.workingColumns.removeLast()
        editor.manager.workingColumns.insert(moved, at: 0)
        editor.refresh()
        let status = id(of: "status", in: editor)
        adapter.select(entity: status)

        editor.manager.deleteColumn(id: added)
        editor.refresh()

        #expect(adapter.selectedEntityIDs == [status])
    }

    @Test("Adding a column selects it, so the inspector opens on it")
    func addingRevealsTheNewRow() {
        let editor = makeEditor()
        editor.add(.columns)
        let added = editor.manager.workingColumns.last!.id

        #expect(editor.inspectorTarget == .entity(.columns, added))
    }

    @Test("Revealing a definition the filter hides clears the filter and selects it")
    func revealClearsAHidingFilter() {
        let editor = makeEditor()
        editor.searchText = "stat"
        let id = id(of: "customer_id", in: editor)

        editor.reveal(section: .columns, entity: id)

        #expect(editor.searchText.isEmpty)
        #expect(editor.inspectorTarget == .entity(.columns, id))
    }

    @Test("A collapsed section stays collapsed for the next table")
    func collapsedSectionsPersist() {
        let editor = makeEditor()
        editor.setExpanded(.indexes, false)

        #expect(!makeEditor().isExpanded(.indexes))
    }

    @Test("A filter shows a collapsed section's matches")
    func filterExpandsCollapsedSections() {
        let editor = makeEditor()
        editor.setExpanded(.columns, false)
        editor.searchText = "stat"

        #expect(editor.isExpanded(.columns))
        #expect(editor.adapter(for: .columns).visibleRowCount == 1)
    }

    @Test("Counts leave out definitions marked for deletion")
    func countsSkipDeletions() {
        let editor = makeEditor()
        editor.manager.deleteColumn(id: id(of: "status", in: editor))

        #expect(editor.count(of: .columns) == 2)
    }

    @Test("MySQL tables offer no index condition, since their DDL drops it")
    func mysqlHasNoIndexCondition() {
        let editor = makeEditor(type: .mysql)
        #expect(!editor.adapter(for: .indexes).provider.columns.contains(String(localized: "Condition")))
        #expect(makeEditor().adapter(for: .indexes).provider.columns.contains(String(localized: "Condition")))
    }

    @Test("A pick after typing is its own undo step")
    func pickAfterTypingIsItsOwnStep() {
        let editor = makeEditor()
        let status = id(of: "status", in: editor)
        editor.typeInspectorField(section: .columns, id: status, field: 0, value: "stat")
        editor.typeInspectorField(section: .columns, id: status, field: 0, value: "state")
        editor.commitInspectorField(section: .columns, id: status, field: 1, value: "VARCHAR(20)")

        editor.manager.undo()
        #expect(editor.manager.workingColumns.contains { $0.name == "state" && $0.dataType != "VARCHAR(20)" })
        editor.manager.undo()
        #expect(editor.manager.workingColumns.contains { $0.name == "status" })
    }

    @Test("Nothing can be edited while the table is read again after a save")
    func awaitingBaselineBlocksEdits() {
        let editor = makeEditor()
        editor.isAwaitingBaseline = true

        #expect(!editor.canAdd(.columns))
        editor.add(.columns)
        #expect(editor.manager.workingColumns.count == 3)
        let status = id(of: "status", in: editor)
        #expect(editor.inspectorForm(for: .columns, id: status)?.isEditable == false)
    }

    @Test("Several rows selected says how many instead of picking one")
    func severalSelected() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        adapter.model.selectRows([
            adapter.rowID(forEntity: id(of: "id", in: editor)),
            adapter.rowID(forEntity: id(of: "status", in: editor))
        ])

        #expect(editor.inspectorTarget == .several(.columns, 2))
    }
}

@MainActor
struct StructureDefinitionPasteTests {
    @Test("Pasting several columns is one undo step")
    func pasteIsOneUndoStep() throws {
        let suite = try EphemeralDefaults()
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "t",
            columns: [
                ColumnInfo(name: "a", dataType: "INT", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "b", dataType: "INT", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: []
        )
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .newTable(connection: TestFixtures.makeConnection(type: .postgresql), databaseName: "db", schemaName: nil),
            defaults: suite.defaults
        )
        editor.refresh()
        let adapter = editor.adapter(for: .columns)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("structure-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        adapter.copyRows(manager.workingColumns.map { adapter.rowID(forEntity: $0.id) }, to: pasteboard)

        adapter.pasteRows(from: pasteboard)
        #expect(manager.workingColumns.count == 4)

        manager.undo()
        #expect(manager.workingColumns.count == 2)
    }
}
