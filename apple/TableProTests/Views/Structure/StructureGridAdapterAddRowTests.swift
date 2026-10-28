//
//  StructureGridAdapterAddRowTests.swift
//  TableProTests
//
//  Add and Delete per sub-tab, the contract the footer +/- buttons, Cmd+Shift+N and the row menus share.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureGridAdapterAddRowTests {
    private func makeAdapter(
        selectedTab: StructureTab = .columns,
        type: DatabaseType = .mysql,
        objectKind: TableInfo.TableType = .table,
        manager: StructureChangeManager = StructureChangeManager()
    ) -> (StructureGridAdapter, StructureChangeManager) {
        let adapter = StructureGridAdapter(
            structureChangeManager: manager,
            connection: TestFixtures.makeConnection(type: type),
            tableName: "t",
            databaseName: "db",
            schemaName: nil,
            objectKind: objectKind,
            isSessionBound: false
        )
        adapter.store.switchSubTab(to: selectedTab)
        adapter.refresh()
        return (adapter, manager)
    }

    private func row(_ sourceIndex: Int) -> RowID {
        StructureRowProvider.rowID(forSourceIndex: sourceIndex)
    }

    private func counts(_ manager: StructureChangeManager) -> [Int] {
        [manager.workingColumns.count, manager.workingIndexes.count, manager.workingForeignKeys.count]
    }

    @Test("Columns sub-tab: Add Row appends a placeholder column")
    func columnsTabAddsColumn() {
        let (adapter, manager) = makeAdapter(selectedTab: .columns)
        let before = manager.workingColumns.count
        adapter.gridAddRow()
        #expect(manager.workingColumns.count == before + 1)
    }

    @Test("Indexes sub-tab: Add Row appends a placeholder index")
    func indexesTabAddsIndex() {
        let (adapter, manager) = makeAdapter(selectedTab: .indexes)
        let before = manager.workingIndexes.count
        adapter.gridAddRow()
        #expect(manager.workingIndexes.count == before + 1)
    }

    @Test("Foreign keys sub-tab: Add Row appends a placeholder foreign key")
    func foreignKeysTabAddsForeignKey() {
        let (adapter, manager) = makeAdapter(selectedTab: .foreignKeys)
        let before = manager.workingForeignKeys.count
        adapter.gridAddRow()
        #expect(manager.workingForeignKeys.count == before + 1)
    }

    @Test("Add Row does nothing on a sub-tab without a grid", arguments: [StructureTab.options, .ddl, .parts, .triggers])
    func gridlessTabAddsNothing(tab: StructureTab) {
        let (adapter, manager) = makeAdapter(selectedTab: tab)
        let before = counts(manager)
        adapter.gridAddRow()
        #expect(counts(manager) == before)
    }

    @Test("Delete does nothing on a sub-tab without a grid", arguments: [StructureTab.options, .ddl, .parts, .triggers])
    func gridlessTabDeletesNothing(tab: StructureTab) {
        let (adapter, manager) = makeAdapter(selectedTab: tab)
        let before = counts(manager)
        adapter.gridDeleteRows([row(0)])
        #expect(counts(manager) == before)
    }

    // SQLite's curated snapshot overrides neither supportsAddIndex nor supportsDropIndex, so both default to true.
    @Test("Indexes sub-tab on SQLite: Add Row appends an index")
    func sqliteIndexesAddsAnIndex() {
        let (adapter, manager) = makeAdapter(selectedTab: .indexes, type: .sqlite)
        let before = manager.workingIndexes.count
        adapter.gridAddRow()
        #expect(manager.workingIndexes.count == before + 1)
    }

    @Test("Columns sub-tab: Delete removes the column the row names")
    func columnsTabDeleteRemovesColumn() {
        let (adapter, manager) = makeAdapter(selectedTab: .columns)
        adapter.gridAddRow()
        let after = manager.workingColumns.count
        #expect(after > 0)
        adapter.gridDeleteRows([row(after - 1)])
        #expect(manager.workingColumns.count == after - 1)
    }

    @Test("Indexes sub-tab: Delete removes the index the row names")
    func indexesTabDeleteRemovesIndex() {
        let (adapter, manager) = makeAdapter(selectedTab: .indexes)
        adapter.gridAddRow()
        let after = manager.workingIndexes.count
        #expect(after > 0)
        adapter.gridDeleteRows([row(after - 1)])
        #expect(manager.workingIndexes.count == after - 1)
    }

    @Test("Foreign keys sub-tab: Delete removes the foreign key the row names")
    func foreignKeysTabDeleteRemovesForeignKey() {
        let (adapter, manager) = makeAdapter(selectedTab: .foreignKeys)
        adapter.gridAddRow()
        let after = manager.workingForeignKeys.count
        #expect(after > 0)
        adapter.gridDeleteRows([row(after - 1)])
        #expect(manager.workingForeignKeys.count == after - 1)
    }

    @Test("Indexes sub-tab on SQLite: Delete removes an index")
    func sqliteIndexesDeletesAnIndex() {
        let manager = StructureChangeManager()
        manager.addIndex(.placeholder())
        let (adapter, _) = makeAdapter(selectedTab: .indexes, type: .sqlite, manager: manager)
        let before = manager.workingIndexes.count

        adapter.gridDeleteRows([row(before - 1)])

        #expect(manager.workingIndexes.count == before - 1)
    }

    @Test("Deleting the last row selects the row above it")
    func deletingTheLastRowSelectsTheOneAbove() {
        let manager = StructureChangeManager()
        for _ in 0..<3 {
            manager.addColumn(.placeholder())
        }
        let (adapter, _) = makeAdapter(selectedTab: .columns, manager: manager)
        adapter.model.selectRows([row(2)])

        adapter.gridDeleteRows([row(2)])

        #expect(manager.workingColumns.count == 2)
        #expect(adapter.model.selectedRowIDs == [row(1)])
    }

    // MARK: - Per object kind

    // Cmd+Shift+N, the row menus and the footer all reach the adapter, so it refuses for itself (#2726).
    @Test("A PostgreSQL view refuses an added column, whatever reaches the adapter")
    func viewRefusesAnAddedColumn() {
        let (adapter, manager) = makeAdapter(selectedTab: .columns, type: .postgresql, objectKind: .view)
        adapter.gridAddRow()
        #expect(manager.workingColumns.isEmpty)
        #expect(!adapter.model.configuration.commands.contains(.addRow))
    }

    @Test("A PostgreSQL view refuses an added index and a materialized view accepts one")
    func indexesFollowTheObjectKind() {
        let (view, viewManager) = makeAdapter(selectedTab: .indexes, type: .postgresql, objectKind: .view)
        view.gridAddRow()
        #expect(viewManager.workingIndexes.isEmpty)

        let (matview, matviewManager) = makeAdapter(
            selectedTab: .indexes, type: .postgresql, objectKind: .materializedView
        )
        matview.gridAddRow()
        #expect(matviewManager.workingIndexes.count == 1)
    }

    @Test("A PostgreSQL materialized view refuses a foreign key")
    func materializedViewRefusesAForeignKey() {
        let (adapter, manager) = makeAdapter(
            selectedTab: .foreignKeys, type: .postgresql, objectKind: .materializedView
        )
        adapter.gridAddRow()
        #expect(manager.workingForeignKeys.isEmpty)
    }

    @Test("A view refuses to drop a column its own grid is showing")
    func viewRefusesADroppedColumn() {
        let manager = StructureChangeManager()
        manager.addColumn(.placeholder())
        #expect(manager.workingColumns.count == 1)
        let (view, _) = makeAdapter(selectedTab: .columns, type: .postgresql, objectKind: .view, manager: manager)

        view.gridDeleteRows([row(0)])

        #expect(manager.workingColumns.count == 1)
        #expect(!view.model.configuration.commands.contains(.deleteRows))
    }

    @Test("A system table refuses every add", arguments: [StructureTab.columns, .indexes, .foreignKeys, .checkConstraints])
    func systemTableRefusesEveryAdd(tab: StructureTab) {
        let (adapter, manager) = makeAdapter(selectedTab: tab, type: .postgresql, objectKind: .systemTable)
        adapter.gridAddRow()
        #expect(manager.workingColumns.isEmpty)
        #expect(manager.workingIndexes.isEmpty)
        #expect(manager.workingForeignKeys.isEmpty)
        #expect(manager.workingCheckConstraints.isEmpty)
    }
}
