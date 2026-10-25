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
    private func makeAdapter(
        tab: StructureTab = .columns,
        type: DatabaseType = .mysql,
        objectKind: TableInfo.TableType = .table,
        manager: StructureChangeManager = StructureChangeManager()
    ) -> StructureGridAdapter {
        if manager.workingColumns.isEmpty {
            manager.addColumn(.placeholder())
        }
        let adapter = StructureGridAdapter(
            structureChangeManager: manager,
            connection: TestFixtures.makeConnection(type: type),
            tableName: "orders",
            databaseName: "shop",
            schemaName: nil,
            objectKind: objectKind,
            isSessionBound: false
        )
        adapter.store.switchSubTab(to: tab)
        adapter.refresh()
        return adapter
    }

    private func row(_ sourceIndex: Int) -> RowID {
        StructureRowProvider.rowID(forSourceIndex: sourceIndex)
    }

    private func titles(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.title }
    }

    @Test("A column row's menu is the schema's own items, with no result commands")
    func columnRowsGetTheStructureMenu() {
        let adapter = makeAdapter()
        let items = titles(adapter.gridRowMenuItems(for: [row(0)], clickedRow: row(0)))

        #expect(items.contains(String(localized: "Copy Name")))
        #expect(items.contains(String(localized: "Copy Definition")))
        let commands = adapter.model.configuration.commands
        #expect(commands.isDisjoint(with: [.exportResults, .showRowsAsJSON, .clearResults, .copyAsSQL, .filterWithColumn]))
    }

    @Test("A DDL tab row offers no row items and no row commands")
    func theDdlTabRaisesNoMenu() {
        let adapter = makeAdapter(tab: .ddl)

        #expect(adapter.gridRowMenuItems(for: [row(0)], clickedRow: row(0)).isEmpty)
        #expect(adapter.gridEmptySpaceMenu() == nil)
        #expect(adapter.model.configuration.commands.isDisjoint(with: [.deleteRows, .duplicateRows, .addRow, .undoDelete]))
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
        let adapter = makeAdapter(manager: manager)
        adapter.gridDeleteRows([row(0)])
        try #require(manager.deleteInsertState(for: 0, tab: .columns).isDeleted)

        #expect(adapter.gridRowMenuItems(for: [row(0)], clickedRow: row(0)).isEmpty)
    }

    // A materialized view refuses DROP COLUMN and ADD COLUMN; the menu used to offer both and do nothing.
    @Test("Delete and Duplicate are offered only where the object accepts them")
    func rowEditsFollowTheGate() {
        let refused = makeAdapter(type: .postgresql, objectKind: .materializedView)
        #expect(refused.model.configuration.commands.isDisjoint(with: [.deleteRows, .duplicateRows]))
        #expect(refused.gridRowMenuItems(for: [row(0)], clickedRow: row(0)).last?.isSeparatorItem == false)

        let accepted = makeAdapter()
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
        let adapter = makeAdapter(tab: .foreignKeys, manager: manager)
        let openCustomers = String(format: String(localized: "Open %@"), "customers")
        let openProducts = String(format: String(localized: "Open %@"), "products")

        #expect(titles(adapter.gridRowMenuItems(for: [row(0)], clickedRow: row(0))).contains(openCustomers))

        let selection = titles(adapter.structureRowMenuItems(for: [row(0), row(1)], clickedRow: row(1)))
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
        let adapter = makeAdapter(manager: manager)
        try #require(adapter.model.configuration.rowReorder.isEnabled)
        var moved: (from: Int, to: Int)?
        adapter.moveRowHandler = { moved = ($0, $1) }

        let items = adapter.structureRowMenuItems(for: [row(0), row(1), row(2)], clickedRow: row(2))
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
        let adapter = makeAdapter(manager: manager)
        adapter.gridDeleteRows([row(1)])
        try #require(manager.deleteInsertState(for: 1, tab: .columns).isDeleted)
        let selection = [row(0), row(1), row(2)]

        let items = titles(adapter.gridRowMenuItems(for: selection, clickedRow: row(0)))
        #expect(items.contains(String(localized: "Copy Name")))
        #expect(items.contains(String(localized: "Copy Definition")))
        #expect(items.contains(String(localized: "Copy As")))
        #expect(titles(adapter.structureRowMenuItems(for: selection, clickedRow: row(2))).contains(String(localized: "Copy Name")))
        #expect(adapter.structureRowMenuItems(for: selection, clickedRow: row(1)).isEmpty)
    }

    @Test("The empty space below the rows offers the sub-tab's own Add")
    func emptySpaceOffersAdd() {
        let columns = makeAdapter(tab: .columns)
        #expect(titles(columns.gridEmptySpaceMenu()?.items ?? []) == [String(localized: "Add Column")])

        let indexes = makeAdapter(tab: .indexes)
        #expect(titles(indexes.gridEmptySpaceMenu()?.items ?? []) == [String(localized: "Add Index")])

        let view = makeAdapter(type: .postgresql, objectKind: .view)
        #expect(view.gridEmptySpaceMenu() == nil)
    }
}
