import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
@Suite("Row Operations Manager")
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
            databaseType: .mysql
        )
        let manager = RowOperationsManager(changeManager: changeManager)
        return (manager, changeManager)
    }

    private func makeTableRows(rowCount: Int) -> TableRows {
        let raw = TestFixtures.makeRows(count: rowCount, columns: Self.testColumns)
        let typed = raw.map { row in row.map(PluginCellValue.fromOptional) }
        return TableRows.from(
            queryRows: typed,
            columns: Self.testColumns,
            columnTypes: Self.testColumnTypes
        )
    }

    private func emptyTableRows() -> TableRows {
        TableRows.from(
            queryRows: [],
            columns: Self.testColumns,
            columnTypes: Self.testColumnTypes
        )
    }

    @Test("addNewRow appends row to tableRows")
    func addNewRowAppendsRow() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)
        let originalCount = tableRows.count

        _ = manager.addNewRow(
            columns: Self.testColumns,
            columnDefaults: [:],
            tableRows: &tableRows
        )

        #expect(tableRows.count == originalCount + 1)
    }

    @Test("addNewRow returns correct row index and inserted delta")
    func addNewRowReturnsCorrectIndex() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 5)

        let result = manager.addNewRow(
            columns: Self.testColumns,
            columnDefaults: [:],
            tableRows: &tableRows
        )

        #expect(result != nil)
        #expect(result?.rowIndex == 5)
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

        let result = manager.addNewRow(
            columns: Self.testColumns,
            columnDefaults: [:],
            tableRows: &tableRows
        )

        #expect(result != nil)
        let newIndex = result!.rowIndex
        #expect(tableRows.rows[newIndex].id.isInserted)
    }

    @Test("addNewRow uses DEFAULT marker for columns with defaults")
    func addNewRowUsesDefaultMarker() {
        let (manager, _) = makeManager()
        var tableRows = emptyTableRows()
        let defaults: [String: String?] = [
            "id": "auto_increment",
            "name": nil,
            "email": "user@example.com",
        ]

        let result = manager.addNewRow(
            columns: Self.testColumns,
            columnDefaults: defaults,
            tableRows: &tableRows
        )

        #expect(result != nil)
        #expect(result?.values[0] == "__DEFAULT__")
        #expect(result?.values[2] == "__DEFAULT__")
    }

    @Test("addNewRow uses nil for columns without defaults")
    func addNewRowUsesNilForNoDefaults() {
        let (manager, _) = makeManager()
        var tableRows = emptyTableRows()
        let defaults: [String: String?] = [
            "id": "auto_increment",
        ]

        let result = manager.addNewRow(
            columns: Self.testColumns,
            columnDefaults: defaults,
            tableRows: &tableRows
        )

        #expect(result != nil)
        #expect(result?.values[1] == nil)
        #expect(result?.values[2] == nil)
    }

    @Test("addNewRow records insertion in change manager")
    func addNewRowRecordsInsertion() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)

        let result = manager.addNewRow(
            columns: Self.testColumns,
            columnDefaults: [:],
            tableRows: &tableRows
        )

        #expect(result != nil)
        #expect(changeManager.hasChanges)
        #expect(changeManager.isRowInserted(result!.rowIndex))
    }

    @Test("addNewRow increments change manager reload version")
    func addNewRowIncrementsReloadVersion() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)
        let versionBefore = changeManager.reloadVersion

        _ = manager.addNewRow(
            columns: Self.testColumns,
            columnDefaults: [:],
            tableRows: &tableRows
        )

        #expect(changeManager.reloadVersion > versionBefore)
    }

    @Test("multiple addNewRow calls append sequential rows")
    func multipleAddNewRowAppendsSequentially() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)

        let r1 = manager.addNewRow(columns: Self.testColumns, columnDefaults: [:], tableRows: &tableRows)
        let r2 = manager.addNewRow(columns: Self.testColumns, columnDefaults: [:], tableRows: &tableRows)
        let r3 = manager.addNewRow(columns: Self.testColumns, columnDefaults: [:], tableRows: &tableRows)

        #expect(tableRows.count == 5)
        #expect(r1?.rowIndex == 2)
        #expect(r2?.rowIndex == 3)
        #expect(r3?.rowIndex == 4)
    }

    @Test("duplicateRow copies source row values")
    func duplicateRowCopiesValues() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)
        let sourceValues = tableRows.rows[1].values

        let result = manager.duplicateRow(
            sourceRowIndex: 1,
            columns: Self.testColumns,
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
            columns: Self.testColumns,
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

    @Test("duplicateRow returns nil for invalid source index")
    func duplicateRowReturnsNilForInvalidIndex() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)

        let result = manager.duplicateRow(
            sourceRowIndex: 10,
            columns: Self.testColumns,
            tableRows: &tableRows
        )

        #expect(result == nil)
    }

    @Test("deleteSelectedRows marks existing rows as deleted")
    func deleteSelectedRowsMarksExistingAsDeleted() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 5)

        _ = manager.deleteSelectedRows(
            selectedIndices: [1, 3],
            tableRows: &tableRows
        )

        #expect(changeManager.hasChanges)
        #expect(changeManager.isRowDeleted(1))
        #expect(changeManager.isRowDeleted(3))
    }

    @Test("deleteSelectedRows removes inserted rows from tableRows and reports delta")
    func deleteSelectedRowsRemovesInsertedRows() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)

        let addResult = manager.addNewRow(
            columns: Self.testColumns,
            columnDefaults: [:],
            tableRows: &tableRows
        )
        #expect(tableRows.count == 4)

        let result = manager.deleteSelectedRows(
            selectedIndices: [addResult!.rowIndex],
            tableRows: &tableRows
        )

        #expect(tableRows.count == 3)
        if case .rowsRemoved(let indices) = result.delta {
            #expect(indices == IndexSet(integer: addResult!.rowIndex))
        } else {
            Issue.record("Expected .rowsRemoved delta")
        }
    }

    @Test("deleteSelectedRows returns correct next selection")
    func deleteSelectedRowsReturnsNextSelection() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 5)

        _ = manager.addNewRow(columns: Self.testColumns, columnDefaults: [:], tableRows: &tableRows)
        #expect(tableRows.count == 6)

        let result = manager.deleteSelectedRows(
            selectedIndices: [5],
            tableRows: &tableRows
        )

        #expect(result.nextRowToSelect >= 0)
        #expect(result.nextRowToSelect < tableRows.count)
    }

    @Test("deleteSelectedRows returns empty result for empty selection")
    func deleteSelectedRowsEmptySelection() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)

        let result = manager.deleteSelectedRows(selectedIndices: [], tableRows: &tableRows)

        #expect(result.physicallyRemovedIndices.isEmpty)
        #expect(result.nextRowToSelect == -1)
        #expect(result.delta == .none)
        #expect(tableRows.count == 3)
    }

    @Test("deleteSelectedRows: deleting only existing rows leaves physicallyRemovedIndices empty")
    func deleteSelectedRowsExistingOnly() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 5)

        let result = manager.deleteSelectedRows(selectedIndices: [1, 3], tableRows: &tableRows)

        #expect(result.physicallyRemovedIndices.isEmpty)
        #expect(result.delta == .none)
        #expect(tableRows.count == 5)
    }

    @Test("deleteSelectedRows: deleting only inserted rows reports each in physicallyRemovedIndices")
    func deleteSelectedRowsInsertedOnly() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)

        _ = manager.addNewRow(columns: Self.testColumns, columnDefaults: [:], tableRows: &tableRows)
        _ = manager.addNewRow(columns: Self.testColumns, columnDefaults: [:], tableRows: &tableRows)
        _ = manager.addNewRow(columns: Self.testColumns, columnDefaults: [:], tableRows: &tableRows)
        #expect(tableRows.count == 5)

        let result = manager.deleteSelectedRows(selectedIndices: [2, 3, 4], tableRows: &tableRows)

        #expect(result.physicallyRemovedIndices == [4, 3, 2])
        #expect(tableRows.count == 2)
        if case .rowsRemoved(let indices) = result.delta {
            #expect(indices == IndexSet([2, 3, 4]))
        } else {
            Issue.record("Expected .rowsRemoved delta")
        }
    }

    @Test("deleteSelectedRows: mixed inserted and existing rows reports only inserted indices")
    func deleteSelectedRowsMixed() {
        let (manager, _) = makeManager()
        var tableRows = makeTableRows(rowCount: 3)

        _ = manager.addNewRow(columns: Self.testColumns, columnDefaults: [:], tableRows: &tableRows)
        #expect(tableRows.count == 4)

        let result = manager.deleteSelectedRows(selectedIndices: [0, 3], tableRows: &tableRows)

        #expect(result.physicallyRemovedIndices == [3])
        #expect(tableRows.count == 3)
    }

    @Test("addNewRow then edit cell preserves insertion state")
    func addNewRowThenEditPreservesInsertion() {
        let (manager, changeManager) = makeManager()
        var tableRows = makeTableRows(rowCount: 2)

        let result = manager.addNewRow(
            columns: Self.testColumns,
            columnDefaults: [:],
            tableRows: &tableRows
        )
        #expect(result != nil)
        let newIndex = result!.rowIndex

        changeManager.recordCellChange(
            rowIndex: newIndex,
            columnIndex: 1,
            columnName: "name",
            oldValue: nil,
            newValue: "Alice"
        )

        #expect(changeManager.hasChanges)
        #expect(changeManager.isRowInserted(newIndex))
        #expect(tableRows.count == 3)
        #expect(tableRows.rows[newIndex].id.isInserted)
    }
}
