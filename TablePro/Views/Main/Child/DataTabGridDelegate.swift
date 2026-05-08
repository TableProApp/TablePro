//
//  DataTabGridDelegate.swift
//  TablePro
//
//  DataGridViewDelegate for the data tab in MainEditorContentView.
//  Bridges delegate calls to MainContentCoordinator and view-level callbacks.
//

import AppKit

@MainActor
final class DataTabGridDelegate: DataGridViewDelegate {
    weak var coordinator: MainContentCoordinator?

    var selectionState: GridSelectionState?

    var onCellEdit: ((Int, Int, String?) -> Void)?
    var onSort: ((Int, Bool, Bool) -> Void)?
    var onClearSort: (() -> Void)?
    var onRemoveSortColumn: ((Int) -> Void)?
    var onAddRow: (() -> Void)?
    var onUndoInsert: ((Int) -> Void)?
    var onFilterColumn: ((String) -> Void)?
    var onRefresh: (() -> Void)?

    // MARK: - DataGridViewDelegate

    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {
        onCellEdit?(row, column, newValue)
    }

    func dataGridSort(column: Int, ascending: Bool, isMultiSort: Bool) {
        onSort?(column, ascending, isMultiSort)
    }

    func dataGridClearSort() {
        onClearSort?()
    }

    func dataGridRemoveSortColumn(_ columnIndex: Int) {
        onRemoveSortColumn?(columnIndex)
    }

    func dataGridAddRow() {
        onAddRow?()
    }

    func dataGridUndoInsert(at index: Int) {
        onUndoInsert?(index)
    }

    func dataGridFilterColumn(_ columnName: String) {
        onFilterColumn?(columnName)
    }

    func dataGridRefresh() {
        onRefresh?()
    }

    func dataGridDeleteRows(_ indices: Set<Int>) {
        coordinator?.deleteSelectedRows(indices: indices)
    }

    func dataGridCopyRows(_ indices: Set<Int>) {
        coordinator?.copySelectedRowsToClipboard(indices: indices)
    }

    func dataGridPasteRows() {
        coordinator?.pasteRows()
    }

    func dataGridDuplicateRow() {
        guard let selectionState, let firstIndex = selectionState.indices.first else { return }
        coordinator?.duplicateSelectedRow(index: firstIndex)
    }

    func dataGridExportResults() {
        NotificationCenter.default.post(name: .exportQueryResults, object: nil)
    }

    func dataGridUndo() {}

    func dataGridRedo() {}

    func dataGridNavigateFK(value: String, fkInfo: ForeignKeyInfo) {
        coordinator?.navigateToFKReference(value: value, fkInfo: fkInfo)
    }

    func dataGridHideColumn(_ columnName: String) {
        coordinator?.hideColumn(columnName)
    }

    func dataGridShowAllColumns() {
        coordinator?.showAllColumns()
    }

    func dataGridEmptySpaceMenu() -> NSMenu? {
        guard let onAddRow else { return nil }
        let menu = NSMenu()
        let target = StructureMenuTarget { onAddRow() }
        let item = NSMenuItem(
            title: String(localized: "Add Row"),
            action: #selector(StructureMenuTarget.addNewItem),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        menu.addItem(item)
        return menu
    }

    weak var tableViewCoordinator: TableViewCoordinator?

    func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {
        self.tableViewCoordinator = tableViewCoordinator
    }

    func dataGridDidInsertRows(at indices: IndexSet) {
        tableViewCoordinator?.applyInsertedRows(indices)
    }

    func dataGridDidRemoveRows(at indices: IndexSet) {
        tableViewCoordinator?.applyRemovedRows(indices)
    }

    func dataGridDidReplaceAllRows() {
        tableViewCoordinator?.applyFullReplace()
    }
}
