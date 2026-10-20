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
    func dataGridDocumentMenuItems(forRow displayRow: Int) -> [NSMenuItem]
    func dataGridHighlightMenuItem(forRow displayRow: Int, dataColumn: Int) -> NSMenuItem?
    func dataGridFilterMenuItem(forRow displayRow: Int, dataColumn: Int) -> NSMenuItem?
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
    /// A cell editor or viewer closed. Told on the turn after, so an editor that closed with a
    /// commit has recorded its edit, which it does after it removes itself.
    func dataGridDidCloseCellOverlay()
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
    /// What an assistive client reads for a cell in place of its drawn text, or nil to read the text.
    func dataGridAccessibilityText(row displayRow: Int, column: Int) -> String?
    /// A status hue for a value cell's text, or nil for the grid text. A selection or find match still
    /// draws its own text color over it.
    func dataGridTextTone(row displayRow: Int, column: Int) -> NSColor?
    /// Nil lets the grid derive the rules from its column types and display formats.
    func dataGridSummaryColumnPolicy() -> SelectionSummaryColumnPolicy?
    /// True when the window ran its own Set Cells to Value over these cells, so the grid's items and the window's do
    /// the same thing.
    func dataGridSetCellsToValue(_ targets: [SetValueTarget]) -> Bool
    /// Runs the cell edits of one command, so an owner that writes each edit through can write them once.
    func dataGridBatchEdits(actionName: String, _ edits: () -> Void)
}

extension DataGridViewDelegate {
    func dataGridDisplayOrderChanged() {}
    func dataGridDisplayFormatChanged() {}
    func dataGridDidCloseCellOverlay() {}
    func dataGridMenuOptions(forRow row: Int, columnIndex: Int) -> [GridMenuOption]? { nil }
    func dataGridCheckboxState(row: Int, column: Int) -> Bool? { nil }
    func dataGridSetCheckbox(_ isOn: Bool, rows: IndexSet, column: Int) {}
    func dataGridAccessibilityText(row displayRow: Int, column: Int) -> String? { nil }
    func dataGridTextTone(row displayRow: Int, column: Int) -> NSColor? { nil }
    func dataGridSummaryColumnPolicy() -> SelectionSummaryColumnPolicy? { nil }
    func dataGridSetCellsToValue(_ targets: [SetValueTarget]) -> Bool { false }
    func dataGridBatchEdits(actionName: String, _ edits: () -> Void) { edits() }
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
    func dataGridDocumentMenuItems(forRow displayRow: Int) -> [NSMenuItem] { [] }
    func dataGridHighlightMenuItem(forRow displayRow: Int, dataColumn: Int) -> NSMenuItem? { nil }
    func dataGridFilterMenuItem(forRow displayRow: Int, dataColumn: Int) -> NSMenuItem? { nil }
    func dataGridHighlightValuesMenuItem(forColumn dataColumnIndex: Int) -> NSMenuItem? { nil }
    func dataGridVisualState(forRow row: Int) -> RowVisualState? { nil }
    func dataGridRowView(for tableView: NSTableView, row: Int, coordinator: TableViewCoordinator) -> NSTableRowView? { nil }
    func dataGridEmptySpaceMenu() -> NSMenu? { nil }
    func dataGridDidInsertRows(at indices: IndexSet) {}
    func dataGridDidRemoveRows(at indices: IndexSet) {}
    func dataGridDidReplaceAllRows() {}
    func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {}
}
