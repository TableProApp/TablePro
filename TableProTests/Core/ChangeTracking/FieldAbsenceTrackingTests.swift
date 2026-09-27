//
//  FieldAbsenceTrackingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct FieldAbsencePendingChangesTests {
    private let row = RowID.existing(0)

    @Test("NULL over a missing field is a change, although both read NULL")
    func nullOverMissingFieldIsAChange() throws {
        var pending = PendingChanges()

        let recorded = pending.recordCellChange(
            rowID: row, columnIndex: 1, columnName: "deletedAt", oldValue: .null, newValue: .null,
            absence: FieldAbsence(wasAbsent: true, isAbsent: false, originalRow: [1])
        )

        #expect(recorded)
        let cell = try #require(pending.changes.first?.cellChanges.first)
        #expect(cell.oldIsAbsent && !cell.newIsAbsent)
        #expect(pending.changes.first?.absentColumns == [1])
    }

    @Test("Removing a field that held NULL is a change")
    func removingANullFieldIsAChange() throws {
        var pending = PendingChanges()

        let recorded = pending.recordCellChange(
            rowID: row, columnIndex: 1, columnName: "deletedAt", oldValue: .null, newValue: .null,
            absence: FieldAbsence(wasAbsent: false, isAbsent: true)
        )

        #expect(recorded)
        #expect(try #require(pending.changes.first?.cellChanges.first).newIsAbsent)
    }

    @Test("Removing a field and then typing its value back leaves nothing pending")
    func removeThenRestoreCollapses() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: row, columnIndex: 1, columnName: "nick", oldValue: "Ada", newValue: .null,
            absence: FieldAbsence(wasAbsent: false, isAbsent: true)
        )
        pending.recordCellChange(
            rowID: row, columnIndex: 1, columnName: "nick", oldValue: .null, newValue: "Ada",
            absence: FieldAbsence(wasAbsent: true, isAbsent: false)
        )

        #expect(pending.isEmpty)
    }

    @Test("Removing a NULL field and setting NULL again leaves nothing pending")
    func removeThenNullOnANullFieldCollapses() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: row, columnIndex: 1, columnName: "nick", oldValue: .null, newValue: .null,
            absence: FieldAbsence(wasAbsent: false, isAbsent: true)
        )
        pending.recordCellChange(
            rowID: row, columnIndex: 1, columnName: "nick", oldValue: .null, newValue: .null,
            absence: FieldAbsence(wasAbsent: true, isAbsent: false)
        )

        #expect(pending.isEmpty)
    }

    @Test("Setting NULL on a field that was removed keeps the field, with the stored value as the old side")
    func nullAfterRemovalIsStillAChange() throws {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: row, columnIndex: 1, columnName: "nick", oldValue: "Ada", newValue: .null,
            absence: FieldAbsence(wasAbsent: false, isAbsent: true)
        )
        pending.recordCellChange(
            rowID: row, columnIndex: 1, columnName: "nick", oldValue: .null, newValue: .null,
            absence: FieldAbsence(wasAbsent: true, isAbsent: false)
        )

        let cell = try #require(pending.changes.first?.cellChanges.first)
        #expect(cell.oldValue == "Ada" && !cell.oldIsAbsent)
        #expect(cell.newValue == .null && !cell.newIsAbsent)
    }

    @Test("A missing field on a new row follows its edits")
    func insertedRowTracksItsMissingFields() {
        var pending = PendingChanges()
        let inserted = RowID.inserted(UUID())
        pending.recordRowInsertion(rowID: inserted, values: ["__DEFAULT__", .null, .null], absentColumns: [1, 2])

        pending.recordCellChange(
            rowID: inserted, columnIndex: 1, columnName: "name", oldValue: .null, newValue: "Ada",
            absence: FieldAbsence(wasAbsent: true, isAbsent: false)
        )
        pending.recordCellChange(
            rowID: inserted, columnIndex: 2, columnName: "deletedAt", oldValue: .null, newValue: .null,
            absence: FieldAbsence(wasAbsent: true, isAbsent: false)
        )

        #expect(pending.insertedAbsentColumns(forRow: inserted).isEmpty)
        #expect(pending.insertedRowData[inserted] == ["__DEFAULT__", "Ada", .null])
    }

    @Test("A snapshot carries the fields a deleted row did not have")
    func snapshotKeepsDeletedRowAbsence() {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowID: row, originalRow: ["1", .null], absentColumns: [1])

        var restored = PendingChanges()
        restored.restore(from: pending.snapshot(primaryKeyColumns: ["_id"], columns: ["_id", "nick"]))

        #expect(restored.change(forRow: row, type: .delete)?.absentColumns == [1])
    }
}

struct FieldAbsenceTableRowsTests {
    private func rows(absentCells: [Int: Set<Int>]) -> TableRows {
        TableRows.from(
            queryRows: [["1", .null, "x"], ["2", .null, .null]],
            columns: ["_id", "deletedAt", "nick"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)],
            absentCells: absentCells
        )
    }

    @Test("Rows keep the fields each result row lacked, and nothing past the last column")
    func rowsKeepAbsence() {
        let tableRows = rows(absentCells: [0: [1], 1: [2, 9]])

        #expect(tableRows.isAbsent(row: 0, column: 1))
        #expect(!tableRows.isAbsent(row: 1, column: 1))
        #expect(tableRows.rows[1].absentColumns == [2])
    }

    @Test("A value written into a missing field brings the field back, and removal takes it out")
    func editMovesAbsence() {
        var tableRows = rows(absentCells: [0: [1]])

        #expect(tableRows.edit(row: 0, column: 1, value: .null) == .cellChanged(row: 0, column: 1))
        #expect(!tableRows.isAbsent(row: 0, column: 1))

        #expect(tableRows.edit(row: 0, column: 2, value: .null, isAbsent: true) == .cellChanged(row: 0, column: 2))
        #expect(tableRows.isAbsent(row: 0, column: 2))
        #expect(tableRows.value(at: 0, column: 2) == .null)
        #expect(tableRows.edit(row: 0, column: 2, value: .null, isAbsent: true) == .none)
    }

    @Test("Several cells can be put back missing at once")
    func editManyRestoresAbsence() {
        var tableRows = rows(absentCells: [:])

        let delta = tableRows.editMany(
            [(row: 0, column: 2, value: .null), (row: 1, column: 1, value: "d")],
            absentCells: [CellPosition(row: 0, column: 2)]
        )

        #expect(delta == .cellsChanged([CellPosition(row: 0, column: 2), CellPosition(row: 1, column: 1)]))
        #expect(tableRows.isAbsent(row: 0, column: 2))
        #expect(!tableRows.isAbsent(row: 1, column: 1))
    }

    @Test("Fetching every row keeps what each row lacks")
    func replaceKeepsAbsence() {
        var tableRows = rows(absentCells: [:])
        tableRows.replace(rows: [["3", .null, "z"]], absentCells: [0: [1]])

        #expect(tableRows.isAbsent(row: 0, column: 1))
    }
}

@MainActor
struct FieldAbsenceUndoTests {
    private func manager() -> (DataChangeManager, UndoManager) {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "items",
            columns: ["_id", "nick"],
            primaryKeyColumns: ["_id"],
            databaseType: .mongodb,
            generatedColumns: []
        )
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        return (manager, undoManager)
    }

    @Test("Undoing Remove Field brings the value back, and redoing it takes the field out again")
    func undoAndRedoOfRemoval() throws {
        let (manager, undoManager) = manager()
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        var tableRows = TableRows.from(
            queryRows: [["1", "Ada"]], columns: ["_id", "nick"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        let operations = RowOperationsManager(changeManager: manager)

        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "nick", oldValue: "Ada", newValue: .null,
            originalRow: ["1", "Ada"], absence: FieldAbsence(wasAbsent: false, isAbsent: true)
        )
        tableRows.edit(row: 0, column: 1, value: .null, isAbsent: true)

        undoManager.undo()
        _ = operations.applyUndoResult(try #require(captured), tableRows: &tableRows)
        #expect(tableRows.value(at: 0, column: 1) == "Ada")
        #expect(!tableRows.isAbsent(row: 0, column: 1))
        #expect(!manager.hasChanges)

        undoManager.redo()
        _ = operations.applyUndoResult(try #require(captured), tableRows: &tableRows)
        #expect(tableRows.isAbsent(row: 0, column: 1))
        let cell = try #require(manager.changes.first?.cellChanges.first)
        #expect(cell.newIsAbsent && !cell.oldIsAbsent)
        #expect(cell.oldValue == "Ada")
    }

    @Test("Redoing a new row's insertion brings back the fields it had none of")
    func redoOfInsertionKeepsMissingFields() throws {
        let (manager, undoManager) = manager()
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        var tableRows = TableRows.from(
            queryRows: [], columns: ["_id", "nick"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        let operations = RowOperationsManager(changeManager: manager)
        let added = try #require(operations.addNewRow(tableRows: &tableRows))
        let missing = manager.pending.insertedAbsentColumns(forRow: added.rowID)
        #expect(!missing.isEmpty)

        undoManager.undo()
        _ = operations.applyUndoResult(try #require(captured), tableRows: &tableRows)
        #expect(tableRows.rows.isEmpty)

        undoManager.redo()
        _ = operations.applyUndoResult(try #require(captured), tableRows: &tableRows)
        #expect(manager.pending.insertedAbsentColumns(forRow: added.rowID) == missing)
        #expect(tableRows.row(withID: added.rowID)?.absentColumns == missing)
        #expect(manager.pending.insertedRowData[added.rowID] == added.values)
    }

    @Test("Undoing a redone insertion takes the row out again")
    func undoAfterRedoRemovesTheRow() throws {
        let (manager, undoManager) = manager()
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        var tableRows = TableRows.from(
            queryRows: [], columns: ["_id", "nick"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        let operations = RowOperationsManager(changeManager: manager)
        let added = try #require(operations.addNewRow(tableRows: &tableRows))

        undoManager.undo()
        _ = operations.applyUndoResult(try #require(captured), tableRows: &tableRows)
        undoManager.redo()
        _ = operations.applyUndoResult(try #require(captured), tableRows: &tableRows)
        undoManager.undo()
        _ = operations.applyUndoResult(try #require(captured), tableRows: &tableRows)

        #expect(!manager.pending.isRowInserted(added.rowID))
        #expect(tableRows.row(withID: added.rowID) == nil)
        #expect(!manager.hasChanges)
    }

    @Test("Discarding puts a removed field back and a filled-in missing field back to missing")
    func originalValuesCarryAbsence() {
        let (manager, _) = manager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "nick", oldValue: .null, newValue: "Ada",
            originalRow: ["1", .null], absence: FieldAbsence(wasAbsent: true, isAbsent: false, originalRow: [1])
        )

        let originals = manager.getOriginalValues()

        #expect(originals.count == 1)
        #expect(originals.first?.isAbsent == true)
        #expect(originals.first?.value == .null)
    }
}
