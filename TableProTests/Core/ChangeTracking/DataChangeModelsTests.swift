//
//  DataChangeModelsTests.swift
//  TableProTests
//
//  Tests for DataChangeModels.swift
//

import Foundation
import Testing
@testable import TablePro

@Suite("Data Change Models")
struct DataChangeModelsTests {

    @Test("ChangeType equality - matching types")
    func changeTypeEquality() {
        #expect(ChangeType.update == ChangeType.update)
        #expect(ChangeType.insert == ChangeType.insert)
        #expect(ChangeType.delete == ChangeType.delete)
    }

    @Test("ChangeType inequality - different types")
    func changeTypeInequality() {
        #expect(ChangeType.insert != ChangeType.delete)
        #expect(ChangeType.update != ChangeType.delete)
        #expect(ChangeType.update != ChangeType.insert)
    }

    @Test("CellChange stores values correctly")
    func cellChangeStoresValues() {
        let cellChange = CellChange(
            rowIndex: 5,
            columnIndex: 2,
            columnName: "email",
            oldValue: "old@example.com",
            newValue: "new@example.com"
        )

        #expect(cellChange.rowIndex == 5)
        #expect(cellChange.columnIndex == 2)
        #expect(cellChange.columnName == "email")
        #expect(cellChange.oldValue == "old@example.com")
        #expect(cellChange.newValue == "new@example.com")
    }

    @Test("CellChange with nil values")
    func cellChangeNilValues() {
        let cellChange = CellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "description",
            oldValue: nil,
            newValue: nil
        )

        #expect(cellChange.oldValue == nil)
        #expect(cellChange.newValue == nil)
    }

    @Test("CellChange has unique id")
    func cellChangeUniqueId() {
        let change1 = CellChange(
            rowIndex: 1,
            columnIndex: 2,
            columnName: "name",
            oldValue: "old",
            newValue: "new"
        )
        let change2 = CellChange(
            rowIndex: 1,
            columnIndex: 2,
            columnName: "name",
            oldValue: "old",
            newValue: "new"
        )

        // Each CellChange gets a unique UUID
        #expect(change1.id != change2.id)
    }

    @Test("RowChange stores values correctly")
    func rowChangeStoresValues() {
        let cellChange = CellChange(
            rowIndex: 3,
            columnIndex: 1,
            columnName: "status",
            oldValue: "active",
            newValue: "inactive"
        )

        let rowChange = RowChange(
            rowIndex: 3,
            type: .update,
            cellChanges: [cellChange],
            originalRow: ["1", "active", "user@example.com"]
        )

        #expect(rowChange.rowIndex == 3)
        #expect(rowChange.type == .update)
        #expect(rowChange.cellChanges.count == 1)
        #expect(rowChange.cellChanges[0] == cellChange)
        #expect(rowChange.originalRow?.count == 3)
    }

    @Test("RowChange with empty cellChanges")
    func rowChangeEmptyCellChanges() {
        let rowChange = RowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        #expect(rowChange.cellChanges.isEmpty)
        #expect(rowChange.originalRow == nil)
        #expect(rowChange.type == .insert)
    }

    @Test("TabChangeSnapshot initializes as empty")
    func tabPendingChangesInit() {
        let pending = TabChangeSnapshot()

        #expect(pending.changes.isEmpty)
        #expect(pending.deletedRowIndices.isEmpty)
        #expect(pending.insertedRowIndices.isEmpty)
        #expect(pending.modifiedCells.isEmpty)
        #expect(pending.insertedRowData.isEmpty)
        #expect(pending.primaryKeyColumns.isEmpty)
        #expect(pending.columns.isEmpty)
    }

    @Test("TabChangeSnapshot hasChanges is false when empty")
    func tabPendingChangesHasChangesEmpty() {
        let pending = TabChangeSnapshot()

        #expect(!pending.hasChanges)
    }

    @Test("TabChangeSnapshot hasChanges is true with changes")
    func tabPendingChangesHasChangesWithChanges() {
        let rowChange = RowChange(
            rowIndex: 0,
            type: .update
        )

        var pending = TabChangeSnapshot()
        pending.changes = [rowChange]

        #expect(pending.hasChanges)
    }

    @Test("TabChangeSnapshot hasChanges is true with deletedRowIndices")
    func tabPendingChangesHasChangesWithDeleted() {
        var pending = TabChangeSnapshot()
        pending.deletedRowIndices = [1, 2, 3]

        #expect(pending.hasChanges)
    }

    @Test("TabChangeSnapshot hasChanges is true with insertedRowIndices")
    func tabPendingChangesHasChangesWithInserted() {
        var pending = TabChangeSnapshot()
        pending.insertedRowIndices = [0, 1]

        #expect(pending.hasChanges)
    }

    @Test("Array safe subscript with valid index")
    func arraySafeSubscriptValid() {
        let array = ["a", "b", "c"]

        #expect(array[safe: 0] == "a")
        #expect(array[safe: 1] == "b")
        #expect(array[safe: 2] == "c")
    }

    @Test("Array safe subscript with out of bounds index returns nil")
    func arraySafeSubscriptOutOfBounds() {
        let array = ["a", "b", "c"]

        #expect(array[safe: -1] == nil)
        #expect(array[safe: 3] == nil)
        #expect(array[safe: 100] == nil)
    }

    @Test("Array safe subscript on empty array")
    func arraySafeSubscriptEmpty() {
        let array: [String] = []

        #expect(array[safe: 0] == nil)
    }
}
