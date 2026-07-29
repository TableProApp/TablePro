//
//  StructureGridDelegateAddRowTests.swift
//  TableProTests
//
//  Tests for StructureGridDelegate.dataGridAddRow() / dataGridDeleteRows(_:)
//  routing per active sub-tab. These cover the contract the new structure
//  footer +/- buttons depend on.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor @Suite("StructureGridDelegate add and delete row routing")
struct StructureGridDelegateAddRowTests {
    private func makeDelegate(
        selectedTab: StructureTab = .columns,
        type: DatabaseType = .mysql
    ) -> (StructureGridDelegate, StructureChangeManager) {
        let manager = StructureChangeManager()
        let connection = TestFixtures.makeConnection(type: type)
        let delegate = StructureGridDelegate(
            structureChangeManager: manager,
            selectedTab: selectedTab,
            connection: connection,
            tableName: "t",
            coordinator: nil
        )
        return (delegate, manager)
    }

    @Test("Columns sub-tab: dataGridAddRow appends a placeholder column")
    func columnsTab_addsColumn() {
        let (delegate, manager) = makeDelegate(selectedTab: .columns)
        let before = manager.workingColumns.count
        delegate.dataGridAddRow()
        #expect(manager.workingColumns.count == before + 1)
    }

    @Test("Indexes sub-tab: dataGridAddRow appends a placeholder index")
    func indexesTab_addsIndex() {
        let (delegate, manager) = makeDelegate(selectedTab: .indexes)
        let before = manager.workingIndexes.count
        delegate.dataGridAddRow()
        #expect(manager.workingIndexes.count == before + 1)
    }

    @Test("Foreign keys sub-tab: dataGridAddRow appends a placeholder foreign key")
    func foreignKeysTab_addsForeignKey() {
        let (delegate, manager) = makeDelegate(selectedTab: .foreignKeys)
        let before = manager.workingForeignKeys.count
        delegate.dataGridAddRow()
        #expect(manager.workingForeignKeys.count == before + 1)
    }

    @Test("DDL sub-tab: dataGridAddRow is a no-op")
    func ddlTab_isNoOp() {
        let (delegate, manager) = makeDelegate(selectedTab: .ddl)
        let columnsBefore = manager.workingColumns.count
        let indexesBefore = manager.workingIndexes.count
        let fksBefore = manager.workingForeignKeys.count
        delegate.dataGridAddRow()
        #expect(manager.workingColumns.count == columnsBefore)
        #expect(manager.workingIndexes.count == indexesBefore)
        #expect(manager.workingForeignKeys.count == fksBefore)
    }

    @Test("Parts sub-tab: dataGridAddRow is a no-op")
    func partsTab_isNoOp() {
        let (delegate, manager) = makeDelegate(selectedTab: .parts)
        let columnsBefore = manager.workingColumns.count
        let indexesBefore = manager.workingIndexes.count
        let fksBefore = manager.workingForeignKeys.count
        delegate.dataGridAddRow()
        #expect(manager.workingColumns.count == columnsBefore)
        #expect(manager.workingIndexes.count == indexesBefore)
        #expect(manager.workingForeignKeys.count == fksBefore)
    }

    @Test("Triggers sub-tab: dataGridAddRow is a no-op")
    func triggersTab_isNoOp() {
        let (delegate, manager) = makeDelegate(selectedTab: .triggers)
        let columnsBefore = manager.workingColumns.count
        let indexesBefore = manager.workingIndexes.count
        let fksBefore = manager.workingForeignKeys.count
        delegate.dataGridAddRow()
        #expect(manager.workingColumns.count == columnsBefore)
        #expect(manager.workingIndexes.count == indexesBefore)
        #expect(manager.workingForeignKeys.count == fksBefore)
    }

    @Test("Delete: triggers sub-tab is a no-op")
    func triggersTab_deleteIsNoOp() {
        let (delegate, manager) = makeDelegate(selectedTab: .triggers)
        let columnsBefore = manager.workingColumns.count
        let indexesBefore = manager.workingIndexes.count
        let fksBefore = manager.workingForeignKeys.count
        delegate.dataGridDeleteRows([0])
        #expect(manager.workingColumns.count == columnsBefore)
        #expect(manager.workingIndexes.count == indexesBefore)
        #expect(manager.workingForeignKeys.count == fksBefore)
    }

    @Test("Indexes sub-tab on SQLite: dataGridAddRow is a no-op (supportsAddIndex == false)")
    func sqliteIndexes_isNoOp() {
        let (delegate, manager) = makeDelegate(selectedTab: .indexes, type: .sqlite)
        let before = manager.workingIndexes.count
        delegate.dataGridAddRow()
        #expect(manager.workingIndexes.count == before)
    }

    @Test("Delete: ddl sub-tab is a no-op")
    func ddlTab_deleteIsNoOp() {
        let (delegate, manager) = makeDelegate(selectedTab: .ddl)
        let columnsBefore = manager.workingColumns.count
        let indexesBefore = manager.workingIndexes.count
        let fksBefore = manager.workingForeignKeys.count
        delegate.dataGridDeleteRows([0])
        #expect(manager.workingColumns.count == columnsBefore)
        #expect(manager.workingIndexes.count == indexesBefore)
        #expect(manager.workingForeignKeys.count == fksBefore)
    }

    @Test("Delete: parts sub-tab is a no-op")
    func partsTab_deleteIsNoOp() {
        let (delegate, manager) = makeDelegate(selectedTab: .parts)
        let columnsBefore = manager.workingColumns.count
        let indexesBefore = manager.workingIndexes.count
        let fksBefore = manager.workingForeignKeys.count
        delegate.dataGridDeleteRows([0])
        #expect(manager.workingColumns.count == columnsBefore)
        #expect(manager.workingIndexes.count == indexesBefore)
        #expect(manager.workingForeignKeys.count == fksBefore)
    }

    @Test("Columns sub-tab: dataGridDeleteRows removes the selected column")
    func columnsTab_deleteRemovesColumn() {
        let (delegate, manager) = makeDelegate(selectedTab: .columns)
        delegate.dataGridAddRow()
        let after = manager.workingColumns.count
        #expect(after > 0)
        delegate.dataGridDeleteRows([after - 1])
        #expect(manager.workingColumns.count == after - 1)
    }

    @Test("Indexes sub-tab: dataGridDeleteRows removes the selected index")
    func indexesTab_deleteRemovesIndex() {
        let (delegate, manager) = makeDelegate(selectedTab: .indexes)
        delegate.dataGridAddRow()
        let after = manager.workingIndexes.count
        #expect(after > 0)
        delegate.dataGridDeleteRows([after - 1])
        #expect(manager.workingIndexes.count == after - 1)
    }

    @Test("Foreign keys sub-tab: dataGridDeleteRows removes the selected foreign key")
    func foreignKeysTab_deleteRemovesForeignKey() {
        let (delegate, manager) = makeDelegate(selectedTab: .foreignKeys)
        delegate.dataGridAddRow()
        let after = manager.workingForeignKeys.count
        #expect(after > 0)
        delegate.dataGridDeleteRows([after - 1])
        #expect(manager.workingForeignKeys.count == after - 1)
    }

    @Test("Indexes sub-tab on SQLite: dataGridDeleteRows is a no-op (supportsDropIndex == false)")
    func sqliteIndexes_deleteIsNoOp() {
        let (delegate, manager) = makeDelegate(selectedTab: .indexes, type: .sqlite)
        manager.addIndex(.placeholder())
        let before = manager.workingIndexes.count
        delegate.dataGridDeleteRows([before - 1])
        #expect(manager.workingIndexes.count == before)
    }
}
