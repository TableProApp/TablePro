//
//  DataTabGridDelegate.swift
//  TablePro
//
//  DataGridViewDelegate for the data tab in MainEditorContentView.
//  Bridges delegate calls to MainContentCoordinator and view-level callbacks.
//

import AppKit
import SwiftUI

@MainActor
final class DataTabGridDelegate: DataGridViewDelegate {
    weak var coordinator: MainContentCoordinator?
    var columnVisibilityManager: ColumnVisibilityManager?

    var selectionState: GridSelectionState?
    var editingCell: Binding<CellPosition?>?

    var onCellEdit: ((Int, Int, String?) -> Void)?
    var onSort: ((Int, Bool, Bool) -> Void)?
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
        NotificationCenter.default.post(
            name: .deleteSelectedRows,
            object: nil,
            userInfo: ["rowIndices": indices]
        )
    }

    func dataGridCopyRows(_ indices: Set<Int>) {
        NotificationCenter.default.post(
            name: .copySelectedRows,
            object: nil,
            userInfo: ["rowIndices": indices]
        )
    }

    func dataGridPasteRows() {
        NotificationCenter.default.post(name: .pasteRows, object: nil)
    }

    func dataGridUndo() {
        coordinator?.undoLastChange()
    }

    func dataGridRedo() {
        coordinator?.redoLastChange()
    }

    func dataGridNavigateFK(value: String, fkInfo: ForeignKeyInfo) {
        coordinator?.navigateToFKReference(value: value, fkInfo: fkInfo)
    }

    func dataGridHideColumn(_ columnName: String) {
        coordinator?.hideColumn(columnName)
    }

    func dataGridShowAllColumns() {
        columnVisibilityManager?.showAll()
        coordinator?.saveColumnVisibilityToTab()
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
}
