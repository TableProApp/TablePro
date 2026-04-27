//
//  RowOperationsManagerTests.swift
//  TableProTests
//
//  Tests for RowOperationsManager row operations: add, duplicate, delete, undo/redo.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("Row Operations Manager")
struct RowOperationsManagerTests {
    // MARK: - Test Helpers

    private func makeManager() -> (RowOperationsManager, DataChangeManager) {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name", "email"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql
        )
        let manager = RowOperationsManager(changeManager: changeManager)
        return (manager, changeManager)
    }

    // MARK: - addNewRow Tests

    @Test("addNewRow appends row to resultRows")
    func addNewRowAppendsRow() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 3)
        let originalCount = rows.count

        _ = manager.addNewRow(
            columns: ["id", "name", "email"],
            columnDefaults: [:],
            resultRows: &rows
        )

        #expect(rows.count == originalCount + 1)
    }

    @Test("addNewRow returns correct row index")
    func addNewRowReturnsCorrectIndex() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 5)

        let result = manager.addNewRow(
            columns: ["id", "name", "email"],
            columnDefaults: [:],
            resultRows: &rows
        )

        #expect(result != nil)
        #expect(result?.rowIndex == 5)
    }

    @Test("addNewRow uses DEFAULT marker for columns with defaults")
    func addNewRowUsesDefaultMarker() {
        let (manager, _) = makeManager()
        var rows: [[String?]] = []
        let defaults: [String: String?] = [
            "id": "auto_increment",
            "name": nil,
            "email": "user@example.com"
        ]

        let result = manager.addNewRow(
            columns: ["id", "name", "email"],
            columnDefaults: defaults,
            resultRows: &rows
        )

        #expect(result != nil)
        #expect(result?.values[0] == "__DEFAULT__")
        #expect(result?.values[2] == "__DEFAULT__")
    }

    @Test("addNewRow uses nil for columns without defaults")
    func addNewRowUsesNilForNoDefaults() {
        let (manager, _) = makeManager()
        var rows: [[String?]] = []
        let defaults: [String: String?] = [
            "id": "auto_increment"
        ]

        let result = manager.addNewRow(
            columns: ["id", "name", "email"],
            columnDefaults: defaults,
            resultRows: &rows
        )

        #expect(result != nil)
        #expect(result?.values[1] == nil)
        #expect(result?.values[2] == nil)
    }

    @Test("addNewRow records insertion in change manager")
    func addNewRowRecordsInsertion() {
        let (manager, changeManager) = makeManager()
        var rows = TestFixtures.makeRows(count: 2)

        let result = manager.addNewRow(
            columns: ["id", "name", "email"],
            columnDefaults: [:],
            resultRows: &rows
        )

        #expect(result != nil)
        #expect(changeManager.hasChanges)
        #expect(changeManager.isRowInserted(result!.rowIndex))
    }

    @Test("addNewRow increments change manager reload version")
    func addNewRowIncrementsReloadVersion() {
        let (manager, changeManager) = makeManager()
        var rows = TestFixtures.makeRows(count: 2)
        let versionBefore = changeManager.reloadVersion

        _ = manager.addNewRow(
            columns: ["id", "name", "email"],
            columnDefaults: [:],
            resultRows: &rows
        )

        #expect(changeManager.reloadVersion > versionBefore)
    }

    @Test("multiple addNewRow calls append sequential rows")
    func multipleAddNewRowAppendsSequentially() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 2)

        let r1 = manager.addNewRow(columns: ["id", "name", "email"], columnDefaults: [:], resultRows: &rows)
        let r2 = manager.addNewRow(columns: ["id", "name", "email"], columnDefaults: [:], resultRows: &rows)
        let r3 = manager.addNewRow(columns: ["id", "name", "email"], columnDefaults: [:], resultRows: &rows)

        #expect(rows.count == 5)
        #expect(r1?.rowIndex == 2)
        #expect(r2?.rowIndex == 3)
        #expect(r3?.rowIndex == 4)
    }

    // MARK: - duplicateRow Tests

    @Test("duplicateRow copies source row values")
    func duplicateRowCopiesValues() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 3)
        let sourceValues = rows[1]

        let result = manager.duplicateRow(
            sourceRowIndex: 1,
            columns: ["id", "name", "email"],
            resultRows: &rows
        )

        #expect(result != nil)
        // Non-PK columns should match source
        #expect(result?.values[1] == sourceValues[1])
        #expect(result?.values[2] == sourceValues[2])
    }

    @Test("duplicateRow sets primary key to DEFAULT")
    func duplicateRowSetsPkToDefault() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 3)

        let result = manager.duplicateRow(
            sourceRowIndex: 0,
            columns: ["id", "name", "email"],
            resultRows: &rows
        )

        #expect(result != nil)
        #expect(result?.values[0] == "__DEFAULT__")
    }

    @Test("duplicateRow returns nil for invalid source index")
    func duplicateRowReturnsNilForInvalidIndex() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 3)

        let result = manager.duplicateRow(
            sourceRowIndex: 10,
            columns: ["id", "name", "email"],
            resultRows: &rows
        )

        #expect(result == nil)
    }

    // MARK: - deleteSelectedRows Tests

    @Test("deleteSelectedRows marks existing rows as deleted")
    func deleteSelectedRowsMarksExistingAsDeleted() {
        let (manager, changeManager) = makeManager()
        var rows = TestFixtures.makeRows(count: 5)

        _ = manager.deleteSelectedRows(
            selectedIndices: [1, 3],
            resultRows: &rows
        )

        #expect(changeManager.hasChanges)
        #expect(changeManager.isRowDeleted(1))
        #expect(changeManager.isRowDeleted(3))
    }

    @Test("deleteSelectedRows removes inserted rows from resultRows")
    func deleteSelectedRowsRemovesInsertedRows() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 3)

        // Insert a new row first
        let result = manager.addNewRow(
            columns: ["id", "name", "email"],
            columnDefaults: [:],
            resultRows: &rows
        )
        #expect(rows.count == 4)

        // Delete the inserted row
        _ = manager.deleteSelectedRows(
            selectedIndices: [result!.rowIndex],
            resultRows: &rows
        )

        #expect(rows.count == 3)
    }

    @Test("deleteSelectedRows returns correct next selection")
    func deleteSelectedRowsReturnsNextSelection() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 5)

        _ = manager.addNewRow(columns: ["id", "name", "email"], columnDefaults: [:], resultRows: &rows)
        #expect(rows.count == 6)

        let result = manager.deleteSelectedRows(
            selectedIndices: [5],
            resultRows: &rows
        )

        #expect(result.nextRowToSelect >= 0)
        #expect(result.nextRowToSelect < rows.count)
    }

    @Test("deleteSelectedRows returns empty physicallyRemovedIndices for empty selection")
    func deleteSelectedRowsEmptySelection() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 3)

        let result = manager.deleteSelectedRows(selectedIndices: [], resultRows: &rows)

        #expect(result.physicallyRemovedIndices.isEmpty)
        #expect(result.nextRowToSelect == -1)
        #expect(rows.count == 3)
    }

    @Test("deleteSelectedRows: deleting only existing rows leaves physicallyRemovedIndices empty")
    func deleteSelectedRowsExistingOnly() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 5)

        let result = manager.deleteSelectedRows(selectedIndices: [1, 3], resultRows: &rows)

        #expect(result.physicallyRemovedIndices.isEmpty)
        #expect(rows.count == 5)
    }

    @Test("deleteSelectedRows: deleting only inserted rows reports each in physicallyRemovedIndices")
    func deleteSelectedRowsInsertedOnly() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 2)

        _ = manager.addNewRow(columns: ["id", "name", "email"], columnDefaults: [:], resultRows: &rows)
        _ = manager.addNewRow(columns: ["id", "name", "email"], columnDefaults: [:], resultRows: &rows)
        _ = manager.addNewRow(columns: ["id", "name", "email"], columnDefaults: [:], resultRows: &rows)
        #expect(rows.count == 5)

        let result = manager.deleteSelectedRows(selectedIndices: [2, 3, 4], resultRows: &rows)

        #expect(result.physicallyRemovedIndices == [4, 3, 2])
        #expect(rows.count == 2)
    }

    @Test("deleteSelectedRows: mixed inserted and existing rows reports only inserted indices")
    func deleteSelectedRowsMixed() {
        let (manager, _) = makeManager()
        var rows = TestFixtures.makeRows(count: 3)

        _ = manager.addNewRow(columns: ["id", "name", "email"], columnDefaults: [:], resultRows: &rows)
        #expect(rows.count == 4)

        let result = manager.deleteSelectedRows(selectedIndices: [0, 3], resultRows: &rows)

        #expect(result.physicallyRemovedIndices == [3])
        #expect(rows.count == 3)
    }

    // MARK: - Integration Tests

    @Test("addNewRow then edit cell preserves insertion state")
    func addNewRowThenEditPreservesInsertion() {
        let (manager, changeManager) = makeManager()
        var rows = TestFixtures.makeRows(count: 2)

        // Add a new row
        let result = manager.addNewRow(
            columns: ["id", "name", "email"],
            columnDefaults: [:],
            resultRows: &rows
        )
        #expect(result != nil)
        let newIndex = result!.rowIndex

        // Edit a cell in the new row
        changeManager.recordCellChange(
            rowIndex: newIndex,
            columnIndex: 1,
            columnName: "name",
            oldValue: nil,
            newValue: "Alice"
        )

        // Both the insertion and the cell edit should be tracked
        #expect(changeManager.hasChanges)
        #expect(changeManager.isRowInserted(newIndex))
        // The row should still exist in resultRows
        #expect(rows.count == 3)
    }
}
