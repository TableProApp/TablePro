import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RowOperationsManagerTests {
    private static let testColumns = ["id", "name", "email"]
    private static let testColumnTypes: [ColumnType] = Array(
        repeating: .text(rawType: nil),
        count: 3
    )

    private func makeManager() -> (RowOperationsManager, DataChangeManager) {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "users",
            columns: Self.testColumns,
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        let manager = RowOperationsManager(changeManager: changeManager)
        return (manager, changeManager)
    }

    private func makeTableRows(
        rowCount: Int,
        columnIdentity: [String: IdentityKind] = [:]
    ) -> TableRows {
        let raw = TestFixtures.makeRows(count: rowCount, columns: Self.testColumns)
        let typed = raw.map { row in row.map(PluginCellValue.fromOptional) }
        return TableRows.from(
            queryRows: typed,
            columns: Self.testColumns,
            columnTypes: Self.testColumnTypes,
            columnIdentity: columnIdentity
        )
    }

    // With no value filter the display order is the storage order.
    private func delete(
        _ displayRows: Set<Int>,
        with manager: RowOperationsManager,
        in tableRows: inout TableRows
    ) -> RowOperationsManager.DeleteRowsResult {
        let rowIDs = displayRows.sorted().compactMap { tableRows.rows.indices.contains($0) ? tableRows.rows[$0].id : nil }
        return manager.deleteRows(
            rowIDs,
            selectedDisplayIndices: displayRows,
            displayCount: tableRows.count,
            tableRows: &tableRows
        )
    }

    private func emptyTableRows(
        columnDefaults: [String: String?] = [:],
        columnIdentity: [String: IdentityKind] = [:],
        generatedColumns: Set<String> = []
    ) -> TableRows {
        TableRows.from(
            queryRows: [],
            columns: Self.testColumns,
            columnTypes: Self.testColumnTypes,
            columnDefaults: columnDefaults,
            columnIdentity: columnIdentity,
            generatedColumns: generatedColumns
        )
    }

    @Test("addNewRow appends row to tableRows")
    func addNewRowAppendsRow() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)
        let originalCount = tableRows.count

        _ = manager.addNewRow(tableRows: &tableRows)

        #expect(tableRows.count == originalCount + 1)
    }

    @Test("addNewRow appends the row it names and reports an inserted delta")
    func addNewRowReturnsCorrectIndex() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 5)

        let result = manager.addNewRow(tableRows: &tableRows)

        #expect(result != nil)
        #expect(result.flatMap { tableRows.index(of: $0.rowID) } == 5)
        if case .rowsInserted(let indices) = result?.delta {
            #expect(indices == IndexSet(integer: 5))
        } else {
            Issue.record("Expected .rowsInserted delta")
        }
    }

    @Test("addNewRow assigns inserted RowID to new row")
    func addNewRowAssignsInsertedRowID() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)

        let result = manager.addNewRow(tableRows: &tableRows)

        #expect(result?.rowID.isInserted == true)
        #expect(tableRows.rows.last?.id == result?.rowID)
    }

    @Test("addNewRow uses DEFAULT marker for columns with defaults")
    func addNewRowUsesDefaultMarker() {
        let (manager, _) = makeManager()
        var tableRows = emptyTableRows(columnDefaults: [
            "id": "auto_increment",
            "name": nil,
            "email": "user@example.com",
        ])

        let result = manager.addNewRow(tableRows: &tableRows)

        #expect(result != nil)
        #expect(result?.values[0] == "__DEFAULT__")
        #expect(result?.values[2] == "__DEFAULT__")
    }

    // PostgreSQL leaves `column_default` null for an identity column, so a new row sent an explicit NULL it refuses.
    @Test(
        "addNewRow uses DEFAULT marker for an identity column that has no default",
        arguments: [IdentityKind.always, IdentityKind.byDefault]
    )
    func addNewRowUsesDefaultMarkerForIdentity(kind: IdentityKind) {
        let (manager, _) = makeManager()
        var tableRows = emptyTableRows(columnIdentity: ["id": kind])

        let result = manager.addNewRow(tableRows: &tableRows)

        #expect(result?.values[0] == "__DEFAULT__")
        #expect(result?.values[1] == .null)
    }

    // Read from the rows: `configureForTable` empties the change manager's copy and a cached rerun never refills it.
    @Test("addNewRow uses DEFAULT marker for a generated column carried on the rows")
    func addNewRowUsesDefaultMarkerForGeneratedColumn() {
        let (manager, changeManager) = makeManager()
        changeManager.setGeneratedColumns([])
        var tableRows = emptyTableRows(generatedColumns: ["email"])

        let result = manager.addNewRow(tableRows: &tableRows)

        #expect(result?.values[2] == "__DEFAULT__")
        #expect(result?.values[1] == .null)
    }

    // A nullable MySQL column and one whose default was dropped both read back NULL (#3058); omitting the latter is ERROR 1364.
    @Test("addNewRow sends NULL rather than DEFAULT for a column whose default is NULL", arguments: ["NULL", "null"])
    func addNewRowSendsNullForNullDefault(spelling: String) {
        let (manager, _) = makeManager()
        var tableRows = emptyTableRows(columnDefaults: ["name": spelling, "email": "'x'"])

        let result = manager.addNewRow(tableRows: &tableRows)

        #expect(result?.values[1] == .null)
        #expect(result?.values[2] == "__DEFAULT__")
        #expect(tableRows.serverAssignsValue(forColumn: "name") == false)
    }

    @Test("addNewRow uses nil for columns without defaults")
    func addNewRowUsesNilForNoDefaults() {
        let (manager, _) = makeManager()
        var tableRows = emptyTableRows(columnDefaults: ["id": "auto_increment"])

        let result = manager.addNewRow(tableRows: &tableRows)

        // An explicit SQL NULL, not a Swift nil: the statement generator treats an absent value differently.
        #expect(result != nil)
        #expect(result?.values[1] == .null)
        #expect(result?.values[2] == .null)
    }

    @Test("addNewRow records insertion in change manager")
    func addNewRowRecordsInsertion() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)

        let result = manager.addNewRow(tableRows: &tableRows)

        #expect(result != nil)
        #expect(changeManager.hasChanges)
        #expect(result.map { changeManager.isRowInserted($0.rowID) } == true)
    }

    @Test("addNewRow increments change manager reload version")
    // `reloadVersion` tells the grid to fetch again, so recording an edit must not move it or the edit is thrown away.
    func addNewRowDoesNotAskTheGridToReload() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)
        let versionBefore = changeManager.reloadVersion

        _ = manager.addNewRow(tableRows: &tableRows)

        #expect(changeManager.reloadVersion == versionBefore)

        changeManager.discardChanges()

        #expect(changeManager.reloadVersion == versionBefore + 1)
    }

    @Test("multiple addNewRow calls append sequential rows")
    func multipleAddNewRowAppendsSequentially() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)

        let r1 = manager.addNewRow(tableRows: &tableRows)
        let r2 = manager.addNewRow(tableRows: &tableRows)
        let r3 = manager.addNewRow(tableRows: &tableRows)

        #expect(tableRows.count == 5)
        #expect(r1.flatMap { tableRows.index(of: $0.rowID) } == 2)
        #expect(r2.flatMap { tableRows.index(of: $0.rowID) } == 3)
        #expect(r3.flatMap { tableRows.index(of: $0.rowID) } == 4)
    }

    @Test("duplicateRow copies source row values")
    func duplicateRowCopiesValues() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)
        let sourceValues = tableRows.rows[1].values

        let result = manager.duplicateRow(
            sourceRowIndex: 1,
            tableRows: &tableRows
        )

        #expect(result != nil)
        #expect(result?.values[1] == sourceValues[1])
        #expect(result?.values[2] == sourceValues[2])
    }

    @Test("duplicateRow sets primary key to DEFAULT and returns inserted delta")
    func duplicateRowSetsPkToDefault() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)

        let result = manager.duplicateRow(
            sourceRowIndex: 0,
            tableRows: &tableRows
        )

        #expect(result != nil)
        #expect(result?.values[0] == "__DEFAULT__")
        if case .rowsInserted(let indices) = result?.delta {
            #expect(indices == IndexSet(integer: 3))
        } else {
            Issue.record("Expected .rowsInserted delta")
        }
    }

    // An identity column need not be the primary key, so the key reset alone left it carrying the source's value.
    @Test("duplicateRow sets a non-key identity column to DEFAULT")
    func duplicateRowResetsNonKeyIdentityColumn() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3, columnIdentity: ["email": .always])
        let sourceValues = tableRows.rows[1].values

        let result = manager.duplicateRow(sourceRowIndex: 1, tableRows: &tableRows)

        #expect(result?.values[2] == "__DEFAULT__")
        #expect(result?.values[1] == sourceValues[1])
    }

    @Test("duplicateRow returns nil for invalid source index")
    func duplicateRowReturnsNilForInvalidIndex() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)

        let result = manager.duplicateRow(
            sourceRowIndex: 10,
            tableRows: &tableRows
        )

        #expect(result == nil)
    }

    @Test("deleteRows marks existing rows as deleted")
    func deleteRowsMarksExistingAsDeleted() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 5)

        _ = delete([1, 3], with: manager, in: &tableRows)

        #expect(changeManager.hasChanges)
        #expect(changeManager.isRowDeleted(.existing(1)))
        #expect(changeManager.isRowDeleted(.existing(3)))
    }

    @Test("deleteRows removes inserted rows from tableRows and reports delta")
    func deleteRowsRemovesInsertedRows() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)

        _ = manager.addNewRow(tableRows: &tableRows)
        #expect(tableRows.count == 4)

        let result = delete([3], with: manager, in: &tableRows)

        #expect(tableRows.count == 3)
        if case .rowsRemoved(let indices) = result.delta {
            #expect(indices == IndexSet(integer: 3))
        } else {
            Issue.record("Expected .rowsRemoved delta")
        }
    }

    @Test("deleteRows returns correct next selection")
    func deleteRowsReturnsNextSelection() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 5)

        _ = manager.addNewRow(tableRows: &tableRows)
        #expect(tableRows.count == 6)

        let result = delete([5], with: manager, in: &tableRows)

        #expect(result.nextRowToSelect >= 0)
        #expect(result.nextRowToSelect < tableRows.count)
    }

    @Test("deleteRows selects the row after the block, or the one before it at the end")
    func deleteRowsNextSelection() {
        let (manager, _) = makeManager()

        var fourRows = makeTableRows(rowCount: 4)
        #expect(delete([1], with: manager, in: &fourRows).nextRowToSelect == 2)

        var fromTheEnd = makeTableRows(rowCount: 4)
        #expect(delete([3], with: manager, in: &fromTheEnd).nextRowToSelect == 2)

        var block = makeTableRows(rowCount: 6)
        #expect(delete([1, 2, 3], with: manager, in: &block).nextRowToSelect == 4)
    }

    @Test("deleteRows counts the rows the removal took out before choosing the next one")
    func deleteRowsNextSelectionAfterRemovals() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)
        _ = manager.addNewRow(tableRows: &tableRows)
        _ = manager.addNewRow(tableRows: &tableRows)

        let result = delete([2, 3], with: manager, in: &tableRows)

        #expect(tableRows.count == 2)
        #expect(result.nextRowToSelect == 1)
    }

    @Test("deleteRows returns empty result for empty selection")
    func deleteRowsEmptySelection() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)

        let result = delete([], with: manager, in: &tableRows)

        #expect(result.physicallyRemovedIndices.isEmpty)
        #expect(result.nextRowToSelect == -1)
        #expect(result.delta == .none)
        #expect(tableRows.count == 3)
    }

    @Test("deleteRows: deleting only existing rows leaves physicallyRemovedIndices empty")
    func deleteRowsExistingOnly() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 5)

        let result = delete([1, 3], with: manager, in: &tableRows)

        #expect(result.physicallyRemovedIndices.isEmpty)
        #expect(result.delta == .none)
        #expect(tableRows.count == 5)
    }

    @Test("deleteRows: deleting only inserted rows reports each in physicallyRemovedIndices")
    func deleteRowsInsertedOnly() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)

        _ = manager.addNewRow(tableRows: &tableRows)
        _ = manager.addNewRow(tableRows: &tableRows)
        _ = manager.addNewRow(tableRows: &tableRows)
        #expect(tableRows.count == 5)

        let result = delete([2, 3, 4], with: manager, in: &tableRows)

        #expect(result.physicallyRemovedIndices == [4, 3, 2])
        #expect(tableRows.count == 2)
        if case .rowsRemoved(let indices) = result.delta {
            #expect(indices == IndexSet([2, 3, 4]))
        } else {
            Issue.record("Expected .rowsRemoved delta")
        }
    }

    @Test("deleteRows: mixed inserted and existing rows reports only inserted indices")
    func deleteRowsMixed() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)

        _ = manager.addNewRow(tableRows: &tableRows)
        #expect(tableRows.count == 4)

        let result = delete([0, 3], with: manager, in: &tableRows)

        #expect(result.physicallyRemovedIndices == [3])
        #expect(tableRows.count == 3)
    }

    @Test("Under a value filter, the row named by identity is the one deleted")
    func deleteRowsUnderFilterMarksTheNamedRow() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 4)
        let shownRow = Array(tableRows.rows[1].values)

        _ = manager.deleteRows([.existing(1)], selectedDisplayIndices: [1], displayCount: 2, tableRows: &tableRows)

        #expect(changeManager.isRowDeleted(.existing(1)))
        #expect(!changeManager.isRowDeleted(.existing(3)))
        #expect(tableRows.count == 4)
        let deleteChange = changeManager.rowChanges.first { $0.type == .delete }
        #expect(deleteChange?.rowID == .existing(1))
        #expect(deleteChange?.originalRow == shownRow)
    }

    @Test("Under a value filter, a selected inserted row is removed from its storage position")
    func deleteRowsUnderFilterRemovesInsertedRow() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)
        guard let addResult = manager.addNewRow(tableRows: &tableRows) else {
            Issue.record("addNewRow returned nil")
            return
        }
        let result = manager.deleteRows([addResult.rowID], selectedDisplayIndices: [1], displayCount: 2, tableRows: &tableRows)

        #expect(tableRows.count == 3)
        #expect(tableRows.index(of: addResult.rowID) == nil)
        #expect(!changeManager.isRowInserted(addResult.rowID))
        #expect(result.physicallyRemovedIndices == [3])
        if case .rowsRemoved(let indices) = result.delta {
            #expect(indices == IndexSet(integer: 3))
        } else {
            Issue.record("Expected .rowsRemoved delta")
        }
    }

    @Test("Undoing the removal of inserted rows puts them back where they were, with their identity")
    func undoRemovedInsertedRowsRestoresThem() {
        let (manager, changeManager) = makeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        changeManager.undoManagerProvider = { undoManager }
        var captured: UndoResult?
        changeManager.onUndoApplied = { captured = $0 }
        var tableRows = makeTableRows(rowCount: 2)
        guard let first = manager.addNewRow(tableRows: &tableRows),
              let second = manager.addNewRow(tableRows: &tableRows) else {
            Issue.record("addNewRow returned nil")
            return
        }

        _ = delete([2, 3], with: manager, in: &tableRows)
        #expect(tableRows.count == 2)

        undoManager.undo()
        guard let captured else {
            Issue.record("No undo result")
            return
        }
        _ = manager.applyUndoResult(captured, tableRows: &tableRows)

        #expect(tableRows.index(of: first.rowID) == 2)
        #expect(tableRows.index(of: second.rowID) == 3)
        #expect(changeManager.isRowInserted(first.rowID))
        #expect(changeManager.isRowInserted(second.rowID))
    }

    @Test("addNewRow then edit cell preserves insertion state")
    func addNewRowThenEditPreservesInsertion() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)

        guard let result = manager.addNewRow(tableRows: &tableRows) else {
            Issue.record("addNewRow returned nil")
            return
        }

        changeManager.recordCellChange(
            rowID: result.rowID,
            columnIndex: 1,
            columnName: "name",
            oldValue: nil,
            newValue: "Alice"
        )

        #expect(changeManager.hasChanges)
        #expect(changeManager.isRowInserted(result.rowID))
        #expect(tableRows.count == 3)
        #expect(tableRows.row(withID: result.rowID) != nil)
    }
}
