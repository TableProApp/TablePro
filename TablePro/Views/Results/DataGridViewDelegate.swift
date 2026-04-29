//
//  DataGridViewDelegate.swift
//  TablePro
//
//  Delegate protocol for DataGridView, replacing closure-based callbacks.
//

import AppKit

@MainActor
protocol DataGridViewDelegate: AnyObject {
    func dataGridDidEditCell(row: Int, column: Int, newValue: String?)
    func dataGridDeleteRows(_ indices: Set<Int>)
    func dataGridCopyRows(_ indices: Set<Int>)
    func dataGridPasteRows()
    func dataGridUndo()
    func dataGridRedo()
    func dataGridAddRow()
    func dataGridUndoInsert(at index: Int)
    func dataGridMoveRow(from source: Int, to destination: Int)
    func dataGridSort(column: Int, ascending: Bool, isMultiSort: Bool)
    func dataGridClearSort()
    func dataGridFilterColumn(_ columnName: String)
    func dataGridNavigateFK(value: String, fkInfo: ForeignKeyInfo)
    func dataGridDuplicateRow()
    func dataGridExportResults()
    func dataGridHideColumn(_ columnName: String)
    func dataGridShowAllColumns()
    func dataGridRefresh()
    func dataGridVisualState(forRow row: Int) -> RowVisualState?
    func dataGridRowView(for tableView: NSTableView, row: Int, coordinator: TableViewCoordinator) -> NSTableRowView?
    func dataGridEmptySpaceMenu() -> NSMenu?
    func dataGridDidInsertRows(at indices: IndexSet)
    func dataGridDidRemoveRows(at indices: IndexSet)
    func dataGridDidReplaceAllRows()
    func dataGridAttach(tableViewCoordinator: TableViewCoordinator)
}

extension DataGridViewDelegate {
    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {}
    func dataGridDeleteRows(_ indices: Set<Int>) {}
    func dataGridCopyRows(_ indices: Set<Int>) {}
    func dataGridPasteRows() {}
    func dataGridUndo() {}
    func dataGridRedo() {}
    func dataGridAddRow() {}
    func dataGridUndoInsert(at index: Int) {}
    func dataGridMoveRow(from source: Int, to destination: Int) {}
    func dataGridSort(column: Int, ascending: Bool, isMultiSort: Bool) {}
    func dataGridClearSort() {}
    func dataGridFilterColumn(_ columnName: String) {}
    func dataGridNavigateFK(value: String, fkInfo: ForeignKeyInfo) {}
    func dataGridDuplicateRow() {}
    func dataGridExportResults() {}
    func dataGridHideColumn(_ columnName: String) {}
    func dataGridShowAllColumns() {}
    func dataGridRefresh() {}
    func dataGridVisualState(forRow row: Int) -> RowVisualState? { nil }
    func dataGridRowView(for tableView: NSTableView, row: Int, coordinator: TableViewCoordinator) -> NSTableRowView? { nil }
    func dataGridEmptySpaceMenu() -> NSMenu? { nil }
    func dataGridDidInsertRows(at indices: IndexSet) {}
    func dataGridDidRemoveRows(at indices: IndexSet) {}
    func dataGridDidReplaceAllRows() {}
    func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {}
}
