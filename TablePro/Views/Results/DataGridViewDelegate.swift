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
    func dataGridCanPasteRows() -> Bool
    func dataGridUndo()
    func dataGridRedo()
    func dataGridAddRow()
    func dataGridUndoInsert(at index: Int)
    func dataGridMoveRow(from source: Int, to destination: Int)
    func dataGridSortStateChanged(_ state: SortState)
    /// Asks the owner to approve a change that re-points the display order before it happens.
    ///
    /// A pending cell edit is recorded against a display row, so anything that changes which row
    /// a position names re-points it: the tint moves and a later edit at that position merges
    /// into another row's change. Sort, pagination and the WHERE filter already confirm; a grid
    /// with no owner has no edits to lose and runs the work directly.
    func dataGridConfirmDisplayOrderChange(then apply: @escaping () -> Void)
    func dataGridFilterColumn(_ columnName: String)
    func dataGridNavigateFK(value: String, fkInfo: ForeignKeyInfo, openInNewTab: Bool)
    func dataGridShowRowAsJSON()
    func dataGridDuplicateRow()
    func dataGridExportResults()
    func dataGridClearResults()
    func dataGridCanClearResults() -> Bool
    func dataGridHideColumn(_ columnName: String)
    func dataGridShowAllColumns()
    func dataGridColumnStructureMenuItems(forColumn dataColumnIndex: Int) -> [NSMenuItem]
    func dataGridRowStructureMenuItems(forRow displayRow: Int) -> [NSMenuItem]
    func dataGridVisualState(forRow row: Int) -> RowVisualState?
    func dataGridRowView(for tableView: NSTableView, row: Int, coordinator: TableViewCoordinator) -> NSTableRowView?
    func dataGridEmptySpaceMenu() -> NSMenu?
    func dataGridDidInsertRows(at indices: IndexSet)
    func dataGridDidRemoveRows(at indices: IndexSet)
    func dataGridDidReplaceAllRows()
    func dataGridAttach(tableViewCoordinator: TableViewCoordinator)
    func dataGridDisplayOrderChanged()
    func dataGridDisplayFormatChanged()
}

extension DataGridViewDelegate {
    func dataGridDisplayOrderChanged() {}
    func dataGridDisplayFormatChanged() {}
    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {}
    func dataGridDeleteRows(_ indices: Set<Int>) {}
    func dataGridCopyRows(_ indices: Set<Int>) {}
    func dataGridPasteRows() {}
    func dataGridCanPasteRows() -> Bool { false }
    func dataGridUndo() {}
    func dataGridRedo() {}
    func dataGridAddRow() {}
    func dataGridUndoInsert(at index: Int) {}
    func dataGridMoveRow(from source: Int, to destination: Int) {}
    func dataGridSortStateChanged(_ state: SortState) {}
    func dataGridConfirmDisplayOrderChange(then apply: @escaping () -> Void) { apply() }
    func dataGridFilterColumn(_ columnName: String) {}
    func dataGridNavigateFK(value: String, fkInfo: ForeignKeyInfo, openInNewTab: Bool) {}
    func dataGridShowRowAsJSON() {}
    func dataGridDuplicateRow() {}
    func dataGridExportResults() {}
    func dataGridClearResults() {}
    func dataGridCanClearResults() -> Bool { false }
    func dataGridHideColumn(_ columnName: String) {}
    func dataGridShowAllColumns() {}
    func dataGridColumnStructureMenuItems(forColumn dataColumnIndex: Int) -> [NSMenuItem] { [] }
    func dataGridRowStructureMenuItems(forRow displayRow: Int) -> [NSMenuItem] { [] }
    func dataGridVisualState(forRow row: Int) -> RowVisualState? { nil }
    func dataGridRowView(for tableView: NSTableView, row: Int, coordinator: TableViewCoordinator) -> NSTableRowView? { nil }
    func dataGridEmptySpaceMenu() -> NSMenu? { nil }
    func dataGridDidInsertRows(at indices: IndexSet) {}
    func dataGridDidRemoveRows(at indices: IndexSet) {}
    func dataGridDidReplaceAllRows() {}
    func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {}
}
