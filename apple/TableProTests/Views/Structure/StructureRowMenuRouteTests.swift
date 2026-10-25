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
        let items = titles(adapter.gridRowMenuItems(for: [row(0)]))

        #expect(items.contains(String(localized: "Copy Name")))
        #expect(items.contains(String(localized: "Copy Definition")))
        let commands = adapter.model.configuration.commands
        #expect(commands.isDisjoint(with: [.exportResults, .showRowsAsJSON, .clearResults, .copyAsSQL, .filterWithColumn]))
    }

    @Test("A DDL tab row offers no row items and no row commands")
    func theDdlTabRaisesNoMenu() {
        let adapter = makeAdapter(tab: .ddl)

        #expect(adapter.gridRowMenuItems(for: [row(0)]).isEmpty)
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

        #expect(adapter.gridRowMenuItems(for: [row(0)]).isEmpty)
    }

    // A materialized view refuses DROP COLUMN and ADD COLUMN; the menu used to offer both and do nothing.
    @Test("Delete and Duplicate are offered only where the object accepts them")
    func rowEditsFollowTheGate() {
        let refused = makeAdapter(type: .postgresql, objectKind: .materializedView)
        #expect(refused.model.configuration.commands.isDisjoint(with: [.deleteRows, .duplicateRows]))
        #expect(refused.gridRowMenuItems(for: [row(0)]).last?.isSeparatorItem == false)

        let accepted = makeAdapter()
        #expect(accepted.model.configuration.commands.isSuperset(of: [.deleteRows, .duplicateRows, .undoDelete]))
    }

    @Test("Open names the referenced table only while one foreign key is targeted")
    func openReferencedTableNeedsOneRow() {
        let manager = StructureChangeManager()
        var first = EditableForeignKeyDefinition.placeholder()
        first.referencedTable = "customers"
        var second = EditableForeignKeyDefinition.placeholder()
        second.referencedTable = "customers"
        manager.addForeignKey(first)
        manager.addForeignKey(second)
        let adapter = makeAdapter(tab: .foreignKeys, manager: manager)
        let open = String(format: String(localized: "Open %@"), "customers")

        #expect(titles(adapter.gridRowMenuItems(for: [row(0)])).contains(open))
        #expect(!titles(adapter.gridRowMenuItems(for: [row(0), row(1)])).contains(open))
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
