//
//  AnyChangeManagerTests.swift
//  TableProTests
//
//  Tests for AnyChangeManager type-erased wrapper and [weak self] sink fix.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
@Suite("AnyChangeManager")
struct AnyChangeManagerTests {
    // MARK: - DataChangeManager Wrapper Tests

    @Test("DataChangeManager wrapper: hasChanges forwards correctly")
    func dataManagerHasChangesForwards() {
        let dataManager = DataChangeManager()
        dataManager.configureForTable(tableName: "users", columns: ["id", "name"], primaryKeyColumns: ["id"])
        let wrapper = AnyChangeManager(dataManager)

        #expect(wrapper.hasChanges == false)

        dataManager.recordCellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "Alice", newValue: "Bob")

        #expect(dataManager.hasChanges == true)
        #expect(wrapper.hasChanges == true)
    }

    @Test("DataChangeManager wrapper: reloadVersion forwards correctly")
    func dataManagerReloadVersionForwards() {
        let dataManager = DataChangeManager()
        dataManager.configureForTable(tableName: "users", columns: ["id", "name"], primaryKeyColumns: ["id"])
        let wrapper = AnyChangeManager(dataManager)

        let initialVersion = wrapper.reloadVersion
        dataManager.reloadVersion += 1

        #expect(wrapper.reloadVersion == initialVersion + 1)
    }

    @Test("isRowDeleted delegates correctly for DataChangeManager")
    func isRowDeletedDelegatesCorrectly() {
        let dataManager = DataChangeManager()
        dataManager.configureForTable(tableName: "users", columns: ["id", "name"], primaryKeyColumns: ["id"])
        let wrapper = AnyChangeManager(dataManager)

        #expect(wrapper.isRowDeleted(0) == false)

        dataManager.recordRowDeletion(rowIndex: 0, originalRow: ["1", "Alice"])

        #expect(wrapper.isRowDeleted(0) == true)
    }

    @Test("recordCellChange forwards to DataChangeManager")
    func recordCellChangeForwards() {
        let dataManager = DataChangeManager()
        dataManager.configureForTable(tableName: "users", columns: ["id", "name"], primaryKeyColumns: ["id"])
        let wrapper = AnyChangeManager(dataManager)

        wrapper.recordCellChange(rowIndex: 0, columnIndex: 1, columnName: "name", oldValue: "Alice", newValue: "Bob", originalRow: ["1", "Alice"])

        #expect(dataManager.hasChanges == true)
        #expect(!wrapper.rowChanges.isEmpty)
    }

    @Test("No retain cycle — wrapper can be deallocated")
    func noRetainCycleOnWrapper() {
        let dataManager = DataChangeManager()
        dataManager.configureForTable(tableName: "users", columns: ["id", "name"], primaryKeyColumns: ["id"])

        weak var weakWrapper: AnyChangeManager?

        do {
            let wrapper = AnyChangeManager(dataManager)
            weakWrapper = wrapper
            #expect(weakWrapper != nil)
        }

        #expect(weakWrapper == nil)
    }

    // MARK: - StructureChangeManager Wrapper Tests

    @Test("StructureChangeManager wrapper: isRowDeleted always returns false")
    func structureManagerIsRowDeletedAlwaysFalse() {
        let structureManager = StructureChangeManager()
        let wrapper = AnyChangeManager(structureManager)

        #expect(wrapper.isRowDeleted(0) == false)
        #expect(wrapper.isRowDeleted(100) == false)
    }

    @Test("StructureChangeManager wrapper: hasChanges forwards correctly when false")
    func structureManagerHasChangesForwardsFalse() {
        let structureManager = StructureChangeManager()
        let wrapper = AnyChangeManager(structureManager)

        #expect(wrapper.hasChanges == false)
    }

    @Test("StructureChangeManager wrapper: hasChanges forwards correctly when true")
    func structureManagerHasChangesForwardsTrue() {
        let structureManager = StructureChangeManager()
        let wrapper = AnyChangeManager(structureManager)

        structureManager.addNewColumn()

        #expect(wrapper.hasChanges == true)
    }

    @Test("StructureChangeManager wrapper: reloadVersion forwards correctly")
    func structureManagerReloadVersionForwards() {
        let structureManager = StructureChangeManager()
        let wrapper = AnyChangeManager(structureManager)

        let initialVersion = wrapper.reloadVersion
        structureManager.reloadVersion = 5

        #expect(wrapper.reloadVersion == 5)
        #expect(wrapper.reloadVersion != initialVersion)
    }
}
