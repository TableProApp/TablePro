//
//  RowProviderSyncTests.swift
//  TableProTests
//
//  Tests for the regression fix: re-applying pending cell edits from
//  DataChangeManager to a fresh (stale/cached) InMemoryRowProvider.
//  Simulates the scenario in DataGridView.updateNSView where SwiftUI
//  provides a cached rowProvider that doesn't reflect in-flight edits.
//

import Foundation
@testable import TablePro
import Testing

@Suite("RowProvider Sync After Replacement")
@MainActor
struct RowProviderSyncTests {
    // MARK: - Helpers

    private func makeScenario(
        rowCount: Int = 3,
        columns: [String] = ["id", "name", "email"]
    ) -> (manager: DataChangeManager, provider: InMemoryRowProvider) {
        let rows = TestFixtures.makeQueryResultRows(count: rowCount, columns: columns)
        let provider = InMemoryRowProvider(rows: rows, columns: columns)
        let manager = DataChangeManager()
        manager.configureForTable(tableName: "test", columns: columns, primaryKeyColumn: "id")
        return (manager, provider)
    }

    /// Simulates the re-apply logic from DataGridView.updateNSView
    private func reapplyChanges(from manager: DataChangeManager, to provider: InMemoryRowProvider) {
        for change in manager.changes {
            for cellChange in change.cellChanges {
                provider.updateValue(
                    cellChange.newValue,
                    at: change.rowIndex,
                    columnIndex: cellChange.columnIndex
                )
            }
        }
    }

    // MARK: - Tests

    @Test("Single cell edit syncs to new provider")
    func singleCellEditSyncsToNewProvider() {
        let (manager, providerA) = makeScenario()
        let originalRow = providerA.rowValues(at: 1)!

        // Edit row 1, col 1: "name_1" → "new"
        manager.recordCellChange(
            rowIndex: 1,
            columnIndex: 1,
            columnName: "name",
            oldValue: "name_1",
            newValue: "new",
            originalRow: originalRow
        )
        providerA.updateValue("new", at: 1, columnIndex: 1)

        // Simulate SwiftUI providing a stale cached provider
        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])
        #expect(providerB.value(atRow: 1, column: 1) == "name_1")

        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 1, column: 1) == "new")
    }

    @Test("Multiple cell edits on same row sync correctly")
    func multipleCellEditsSameRowSync() {
        let (manager, providerA) = makeScenario()
        let originalRow = providerA.rowValues(at: 0)!

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "name_0",
            newValue: "updated_name",
            originalRow: originalRow
        )
        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 2,
            columnName: "email",
            oldValue: "email_0",
            newValue: "updated_email",
            originalRow: originalRow
        )

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 0, column: 1) == "updated_name")
        #expect(providerB.value(atRow: 0, column: 2) == "updated_email")
    }

    @Test("Multiple cell edits on different rows sync correctly")
    func multipleCellEditsDifferentRowsSync() {
        let (manager, providerA) = makeScenario()
        let originalRow0 = providerA.rowValues(at: 0)!
        let originalRow2 = providerA.rowValues(at: 2)!

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "name_0",
            newValue: "new_name_0",
            originalRow: originalRow0
        )
        manager.recordCellChange(
            rowIndex: 2,
            columnIndex: 2,
            columnName: "email",
            oldValue: "email_2",
            newValue: "new_email_2",
            originalRow: originalRow2
        )

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 0, column: 1) == "new_name_0")
        #expect(providerB.value(atRow: 2, column: 2) == "new_email_2")
    }

    @Test("Edit then undo leaves provider unchanged")
    func editThenUndoLeavesProviderUnchanged() {
        let (manager, providerA) = makeScenario()
        let originalRow = providerA.rowValues(at: 1)!

        manager.recordCellChange(
            rowIndex: 1,
            columnIndex: 1,
            columnName: "name",
            oldValue: "name_1",
            newValue: "edited",
            originalRow: originalRow
        )

        _ = manager.undoLastChange()

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 1, column: 1) == "name_1")
    }

    @Test("Edit, undo, redo syncs correctly")
    func editUndoRedoSyncsCorrectly() {
        let (manager, providerA) = makeScenario()
        let originalRow = providerA.rowValues(at: 1)!

        manager.recordCellChange(
            rowIndex: 1,
            columnIndex: 1,
            columnName: "name",
            oldValue: "name_1",
            newValue: "new",
            originalRow: originalRow
        )

        _ = manager.undoLastChange()
        _ = manager.redoLastChange()

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 1, column: 1) == "new")
    }

    @Test("Inserted row cell edit syncs to new provider")
    func insertedRowCellEditSyncs() {
        let columns = ["id", "name", "email"]
        let (manager, providerA) = makeScenario(columns: columns)

        // Insert a new row at index 3
        manager.recordRowInsertion(rowIndex: 3, values: ["", "", ""])
        _ = providerA.appendRow(values: ["", "", ""])

        // Edit cell on the inserted row
        manager.recordCellChange(
            rowIndex: 3,
            columnIndex: 1,
            columnName: "name",
            oldValue: "",
            newValue: "inserted_val",
            originalRow: nil
        )

        // Fresh providerB needs 4 rows to match
        var rows = TestFixtures.makeQueryResultRows(count: 3, columns: columns)
        rows.append(QueryResultRow(id: 3, values: ["", "", ""]))
        let providerB = InMemoryRowProvider(rows: rows, columns: columns)

        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 3, column: 1) == "inserted_val")
    }

    @Test("Deleted row does not affect sync")
    func deletedRowDoesNotAffectSync() {
        let (manager, providerA) = makeScenario()
        let originalRow = providerA.rowValues(at: 1)!

        manager.recordRowDeletion(rowIndex: 1, originalRow: originalRow)

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        // Should not crash; delete changes have no cellChanges
        reapplyChanges(from: manager, to: providerB)

        // ProviderB values remain unchanged
        #expect(providerB.value(atRow: 0, column: 0) == "id_0")
        #expect(providerB.value(atRow: 1, column: 1) == "name_1")
        #expect(providerB.value(atRow: 2, column: 2) == "email_2")
    }

    @Test("Multiple edits to same cell — last value wins")
    func multipleEditsToSameCellLastValueWins() {
        let (manager, providerA) = makeScenario()
        let originalRow = providerA.rowValues(at: 0)!

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "name_0",
            newValue: "b",
            originalRow: originalRow
        )
        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "b",
            newValue: "c",
            originalRow: originalRow
        )

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 0, column: 1) == "c")
    }

    @Test("Reapply is idempotent")
    func reapplyIsIdempotent() {
        let (manager, providerA) = makeScenario()
        let originalRow = providerA.rowValues(at: 0)!

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "name_0",
            newValue: "updated",
            originalRow: originalRow
        )

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 0, column: 1) == "updated")

        // Apply again — should remain correct, no corruption
        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 0, column: 1) == "updated")
    }

    @Test("Null value syncs correctly")
    func nullValueSyncsCorrectly() {
        let (manager, providerA) = makeScenario()
        let originalRow = providerA.rowValues(at: 0)!

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "name_0",
            newValue: nil,
            originalRow: originalRow
        )

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        reapplyChanges(from: manager, to: providerB)
        #expect(providerB.value(atRow: 0, column: 1) == nil)
    }

    @Test("Reapply with no changes is a no-op")
    func reapplyWithNoChangesIsNoOp() {
        let (manager, _) = makeScenario()

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        reapplyChanges(from: manager, to: providerB)

        #expect(providerB.value(atRow: 0, column: 0) == "id_0")
        #expect(providerB.value(atRow: 0, column: 1) == "name_0")
        #expect(providerB.value(atRow: 0, column: 2) == "email_0")
        #expect(providerB.value(atRow: 1, column: 0) == "id_1")
        #expect(providerB.value(atRow: 1, column: 1) == "name_1")
        #expect(providerB.value(atRow: 2, column: 2) == "email_2")
    }

    @Test("Batch delete does not crash")
    func batchDeleteDoesNotCrash() {
        let (manager, providerA) = makeScenario()
        let originalRow0 = providerA.rowValues(at: 0)!
        let originalRow1 = providerA.rowValues(at: 1)!

        manager.recordBatchRowDeletion(rows: [
            (rowIndex: 0, originalRow: originalRow0),
            (rowIndex: 1, originalRow: originalRow1),
        ])

        let rows = TestFixtures.makeQueryResultRows(count: 3, columns: ["id", "name", "email"])
        let providerB = InMemoryRowProvider(rows: rows, columns: ["id", "name", "email"])

        // Should not crash; batch delete changes have no cellChanges
        reapplyChanges(from: manager, to: providerB)

        // Values remain unchanged
        #expect(providerB.value(atRow: 0, column: 0) == "id_0")
        #expect(providerB.value(atRow: 1, column: 1) == "name_1")
        #expect(providerB.value(atRow: 2, column: 2) == "email_2")
    }
}
