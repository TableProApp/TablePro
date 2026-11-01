//
//  StructureRowMenuRouteTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Every row menu, from any click and either pane, is the grid's commands plus the owner's `gridRowMenuItems`.
@MainActor
struct StructureRowMenuRouteTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeEditor(
        type: DatabaseType = .mysql,
        objectKind: TableInfo.TableType = .table,
        manager: StructureChangeManager = StructureChangeManager()
    ) -> StructureDefinitionEditor {
        if manager.workingColumns.isEmpty {
            manager.addColumn(.placeholder())
        }
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .existingTable(
                connection: TestFixtures.makeConnection(type: type),
                databaseName: "shop",
                schemaName: nil,
                tableName: "orders",
                objectKind: objectKind,
                isSessionBound: false
            ),
            defaults: suite.defaults
        )
        editor.refresh()
        return editor
    }

    private func row(_ sourceIndex: Int, in adapter: StructureSectionAdapter) -> RowID {
        adapter.rowID(forEntity: StructureGridEdits.entityIDs(in: adapter.section, manager: adapter.manager)[sourceIndex])
    }

    private func titles(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.title }
    }

    @Test("A column row's menu is the schema's own items, with no result commands")
    func columnRowsGetTheStructureMenu() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        let items = titles(adapter.gridRowMenuItems(for: [row(0, in: adapter)], clickedRow: row(0, in: adapter)))

        #expect(items.contains(String(localized: "Copy Name")))
        #expect(items.contains(String(localized: "Copy Definition")))
        let commands = adapter.model.configuration.commands
        #expect(commands.isDisjoint(with: [.exportResults, .showRowsAsJSON, .clearResults, .copyAsSQL, .filterWithColumn]))
    }

    @Test("A row pending deletion offers none of the schema's items")
    func deletedRowOffersNothing() throws {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        let editor = makeEditor(manager: manager)
        let adapter = editor.adapter(for: .columns)
        let id = row(0, in: adapter)
        adapter.gridDeleteRows([id])
        try #require(manager.deleteInsertState(for: 0, tab: .columns).isDeleted)

        #expect(adapter.gridRowMenuItems(for: [id], clickedRow: id).isEmpty)
    }

    // A materialized view refuses DROP COLUMN and ADD COLUMN; the menu used to offer both and do nothing.
    @Test("Delete and Duplicate are offered only where the object accepts them")
    func rowEditsFollowTheGate() {
        let refusedEditor = makeEditor(type: .postgresql, objectKind: .materializedView)
        let refused = refusedEditor.adapter(for: .columns)
        #expect(refused.model.configuration.commands.isDisjoint(with: [.deleteRows, .duplicateRows]))
        #expect(refused.gridRowMenuItems(for: [row(0, in: refused)], clickedRow: row(0, in: refused)).last?.isSeparatorItem == false)

        let acceptedEditor = makeEditor()
        let accepted = acceptedEditor.adapter(for: .columns)
        #expect(accepted.model.configuration.commands.isSuperset(of: [.deleteRows, .duplicateRows, .undoDelete]))
    }

    @Test("Open names the clicked foreign key's table, also inside a multi-row selection")
    func openFollowsTheClickedRow() {
        let manager = StructureChangeManager()
        var first = EditableForeignKeyDefinition.placeholder()
        first.referencedTable = "customers"
        var second = EditableForeignKeyDefinition.placeholder()
        second.referencedTable = "products"
        manager.addForeignKey(first)
        manager.addForeignKey(second)
        let editor = makeEditor(manager: manager)
        let adapter = editor.adapter(for: .foreignKeys)
        let openCustomers = String(format: String(localized: "Open %@"), "customers")
        let openProducts = String(format: String(localized: "Open %@"), "products")

        #expect(titles(adapter.gridRowMenuItems(for: [row(0, in: adapter)], clickedRow: row(0, in: adapter))).contains(openCustomers))

        let selection = titles(adapter.rowMenuItems(for: [row(0, in: adapter), row(1, in: adapter)], clickedRow: row(1, in: adapter)))
        #expect(selection.contains(openProducts))
        #expect(!selection.contains(openCustomers))
    }

    @Test("Move Column moves the clicked column, also inside a multi-row selection")
    func moveFollowsTheClickedRow() throws {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true),
                ColumnInfo(name: "total", dataType: "INT", isNullable: true, isPrimaryKey: false),
                ColumnInfo(name: "note", dataType: "TEXT", isNullable: true, isPrimaryKey: false)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        let editor = makeEditor(manager: manager)
        let adapter = editor.adapter(for: .columns)
        try #require(adapter.model.configuration.rowReorder.isEnabled)
        var moved: (from: Int, to: Int)?
        editor.moveColumnHandler = { moved = ($0, $1) }

        let items = adapter.rowMenuItems(
            for: [row(0, in: adapter), row(1, in: adapter), row(2, in: adapter)],
            clickedRow: row(2, in: adapter)
        )
        let up = try #require(items.first { $0.title == String(localized: "Move Column Up") })
        let down = try #require(items.first { $0.title == String(localized: "Move Column Down") })
        #expect(up.action != nil)
        #expect(down.action == nil)

        let target = try #require(up.target as? StructureMenuTarget)
        target.runAction()
        #expect(moved?.from == 2)
        #expect(moved?.to == ColumnMove.dropIndex(movingRow: 2, .up))
    }

    @Test("A deleted row elsewhere in the selection leaves the schema items in place")
    func deletedRowInSelectionKeepsTheItems() throws {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true),
                ColumnInfo(name: "total", dataType: "INT", isNullable: true, isPrimaryKey: false),
                ColumnInfo(name: "note", dataType: "TEXT", isNullable: true, isPrimaryKey: false)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        let editor = makeEditor(manager: manager)
        let adapter = editor.adapter(for: .columns)
        let rows = [row(0, in: adapter), row(1, in: adapter), row(2, in: adapter)]
        adapter.gridDeleteRows([rows[1]])
        try #require(manager.deleteInsertState(for: 1, tab: .columns).isDeleted)

        let items = titles(adapter.gridRowMenuItems(for: rows, clickedRow: rows[0]))
        #expect(items.contains(String(localized: "Copy Name")))
        #expect(items.contains(String(localized: "Copy Definition")))
        #expect(items.contains(String(localized: "Copy As")))
        #expect(titles(adapter.rowMenuItems(for: rows, clickedRow: rows[2])).contains(String(localized: "Copy Name")))
        #expect(adapter.rowMenuItems(for: rows, clickedRow: rows[1]).isEmpty)
    }
}
