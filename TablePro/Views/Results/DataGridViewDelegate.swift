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
    func dataGridMoveRow(from source: Int, to destination: Int)
    func dataGridSortStateChanged(_ state: SortState)
    func dataGridConfirmDisplayOrderChange(then apply: @escaping () -> Void)
    func dataGridFilterColumn(_ columnName: String)
    func dataGridNavigateFK(value: String, fkInfo: ForeignKeyInfo, intent: ReferenceOpenIntent)
    func dataGridShowRowAsJSON()
    func dataGridDuplicateRow()
    func dataGridExportResults()
    func dataGridClearResults()
    func dataGridCanClearResults() -> Bool
    func dataGridHideColumn(_ columnName: String)
    func dataGridShowAllColumns()
    func dataGridColumnStructureMenuItems(forColumn dataColumnIndex: Int) -> [NSMenuItem]
    func dataGridRowStructureMenuItems(forRow displayRow: Int) -> [NSMenuItem]
    func dataGridHighlightMenuItem(forRow displayRow: Int, dataColumn: Int) -> NSMenuItem?
    func dataGridHighlightValuesMenuItem(forColumn dataColumnIndex: Int) -> NSMenuItem?
    func dataGridVisualState(forRow row: Int) -> RowVisualState?
    func dataGridRowView(for tableView: NSTableView, row: Int, coordinator: TableViewCoordinator) -> NSTableRowView?
    func dataGridEmptySpaceMenu() -> NSMenu?
    func dataGridDidInsertRows(at indices: IndexSet)
    func dataGridDidRemoveRows(at indices: IndexSet)
    func dataGridDidReplaceAllRows()
    func dataGridAttach(tableViewCoordinator: TableViewCoordinator)
    func dataGridDisplayOrderChanged()
    func dataGridDisplayFormatChanged()
    /// The menu this particular cell should offer, when the list depends on the row rather than
    /// only on the column.
    ///
    /// `DataGridConfiguration.customDropdownOptions` is keyed by column alone, which cannot express
    /// a foreign key's Ref Columns: the list is the columns of whatever table that row's Ref Table
    /// names. Returning nil falls back to that dictionary.
    func dataGridMenuOptions(forRow row: Int, columnIndex: Int) -> [GridMenuOption]?
    /// A checkbox cell's state, or nil when that row offers no checkbox.
    func dataGridCheckboxState(row: Int, column: Int) -> Bool?
    func dataGridSetCheckbox(_ isOn: Bool, rows: IndexSet, column: Int)
}

extension DataGridViewDelegate {
    func dataGridDisplayOrderChanged() {}
    func dataGridDisplayFormatChanged() {}
    func dataGridMenuOptions(forRow row: Int, columnIndex: Int) -> [GridMenuOption]? { nil }
    func dataGridCheckboxState(row: Int, column: Int) -> Bool? { nil }
    func dataGridSetCheckbox(_ isOn: Bool, rows: IndexSet, column: Int) {}
    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {}
    func dataGridDeleteRows(_ indices: Set<Int>) {}
    func dataGridCopyRows(_ indices: Set<Int>) {}
    func dataGridPasteRows() {}
    func dataGridCanPasteRows() -> Bool { false }
    func dataGridUndo() {}
    func dataGridRedo() {}
    func dataGridAddRow() {}
    func dataGridMoveRow(from source: Int, to destination: Int) {}
    func dataGridSortStateChanged(_ state: SortState) {}
    func dataGridConfirmDisplayOrderChange(then apply: @escaping () -> Void) { apply() }
    func dataGridFilterColumn(_ columnName: String) {}
    func dataGridNavigateFK(value: String, fkInfo: ForeignKeyInfo, intent: ReferenceOpenIntent) {}
    func dataGridShowRowAsJSON() {}
    func dataGridDuplicateRow() {}
    func dataGridExportResults() {}
    func dataGridClearResults() {}
    func dataGridCanClearResults() -> Bool { false }
    func dataGridHideColumn(_ columnName: String) {}
    func dataGridShowAllColumns() {}
    func dataGridColumnStructureMenuItems(forColumn dataColumnIndex: Int) -> [NSMenuItem] { [] }
    func dataGridRowStructureMenuItems(forRow displayRow: Int) -> [NSMenuItem] { [] }
    func dataGridHighlightMenuItem(forRow displayRow: Int, dataColumn: Int) -> NSMenuItem? { nil }
    func dataGridHighlightValuesMenuItem(forColumn dataColumnIndex: Int) -> NSMenuItem? { nil }
    func dataGridVisualState(forRow row: Int) -> RowVisualState? { nil }
    func dataGridRowView(for tableView: NSTableView, row: Int, coordinator: TableViewCoordinator) -> NSTableRowView? { nil }
    func dataGridEmptySpaceMenu() -> NSMenu? { nil }
    func dataGridDidInsertRows(at indices: IndexSet) {}
    func dataGridDidRemoveRows(at indices: IndexSet) {}
    func dataGridDidReplaceAllRows() {}
    func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {}
}
