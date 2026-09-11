//
//  DataTabGridDelegate.swift
//  TablePro
//
//  DataGridViewDelegate for the data tab in MainEditorContentView.
//  Bridges delegate calls to MainContentCoordinator and view-level callbacks.
//

import AppKit
import Combine

@MainActor
final class DataTabGridDelegate: DataGridViewDelegate {
    weak var coordinator: MainContentCoordinator?

    var selectionState: GridSelectionState?

    var onCellEdit: ((Int, Int, String?) -> Void)?
    var onSortStateChanged: ((SortState) -> Void)?
    var onAddRow: (() -> Void)?
    var onUndoInsert: ((Int) -> Void)?
    var onFilterColumn: ((String) -> Void)?

    // MARK: - DataGridViewDelegate

    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {
        onCellEdit?(row, column, newValue)
    }

    func dataGridSortStateChanged(_ state: SortState) {
        onSortStateChanged?(state)
    }

    /// The same gate sort, pagination and the WHERE filter go through. `confirmDiscardChangesIfNeeded`
    /// answers immediately when there is nothing to lose, so an unedited result never sees an alert.
    func dataGridConfirmDisplayOrderChange(then apply: @escaping () -> Void) {
        guard let coordinator else {
            apply()
            return
        }
        coordinator.confirmDiscardRestoringRowsIfNeeded(action: .displayOrder) { confirmed in
            guard confirmed else { return }
            apply()
        }
    }

    func dataGridDisplayOrderChanged() {
        coordinator?.gridDisplayRevision &+= 1
    }

    func dataGridDisplayFormatChanged() {
        coordinator?.gridDisplayRevision &+= 1
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

    func dataGridDeleteRows(_ indices: Set<Int>) {
        coordinator?.deleteSelectedRows(indices: indices)
    }

    func dataGridCopyRows(_ indices: Set<Int>) {
        coordinator?.copySelectedRowsToClipboard(indices: indices)
    }

    func dataGridPasteRows() {
        coordinator?.pasteRows()
    }

    func dataGridCanPasteRows() -> Bool {
        coordinator?.commandActions?.canPasteRows ?? false
    }

    func dataGridDuplicateRow() {
        guard let selectionState, let firstIndex = selectionState.indices.first else { return }
        coordinator?.duplicateSelectedRow(index: firstIndex)
    }

    func dataGridExportResults() {
        AppCommands.shared.exportQueryResults.send(())
    }

    func dataGridClearResults() {
        coordinator?.clearActiveQueryResults()
    }

    func dataGridCanClearResults() -> Bool {
        coordinator?.canClearActiveQueryResults ?? false
    }

    func dataGridNavigateFK(value: String, fkInfo: ForeignKeyInfo, openInNewTab: Bool) {
        coordinator?.navigateToFKReference(value: value, fkInfo: fkInfo, openInNewTab: openInNewTab)
    }

    /// The panel reads the selection, not a row this is told about.
    ///
    /// `KeyHandlingTableView.menu(for:)` retargets the selection to a row clicked outside it, so
    /// the usual single-row case shows the row the reader asked about. A click inside a multi-row
    /// selection keeps that selection on purpose, and the panel then shows its first row, which is
    /// the row the Details tab shows too.
    func dataGridShowRowAsJSON() {
        coordinator?.showRowAsJSON()
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
            action: #selector(StructureMenuTarget.runAction),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        menu.addItem(item)
        return menu
    }

    func dataGridHighlightMenuItem(forRow displayRow: Int, dataColumn: Int) -> NSMenuItem? {
        guard let coordinator,
              let grid = tableViewCoordinator,
              let tab = coordinator.tabManager.selectedTab,
              let row = grid.displayRow(at: displayRow) else { return nil }
        let tableRows = grid.tableRowsProvider()
        let columns = tableRows.columns
        guard columns.indices.contains(dataColumn), dataColumn < row.values.count else { return nil }

        let tabId = tab.id
        let context = HighlightMenuBuilder.CellContext(
            columnName: columns[dataColumn],
            columnOccurrence: HighlightRuleSet.occurrence(ofColumnAt: dataColumn, in: columns),
            columnType: dataColumn < tableRows.columnTypes.count ? tableRows.columnTypes[dataColumn] : nil,
            value: row.values[dataColumn],
            existingRules: coordinator.highlightRules(for: tab)
        )
        let actions = HighlightMenuBuilder.Actions(
            apply: { [weak coordinator] rule in
                coordinator?.applyQuickHighlight(rule, forTab: tabId)
            },
            remove: { [weak coordinator] rule in
                coordinator?.removeHighlightRules(sharingConditionWith: rule, forTab: tabId)
            },
            showRules: { [weak coordinator] in
                coordinator?.presentHighlightRules()
            }
        )
        return HighlightMenuBuilder.menuItem(for: context, actions: actions)
    }

    func dataGridHighlightValuesMenuItem(forColumn dataColumnIndex: Int) -> NSMenuItem? {
        guard coordinator != nil, let grid = tableViewCoordinator else { return nil }
        let columns = grid.tableRowsProvider().columns
        guard columns.indices.contains(dataColumnIndex) else { return nil }
        let columnName = columns[dataColumnIndex]
        let occurrence = HighlightRuleSet.occurrence(ofColumnAt: dataColumnIndex, in: columns)
        return ClosureMenuTarget.item(title: String(localized: "Highlight Values…")) { [weak coordinator] in
            coordinator?.presentHighlightRules(addingRuleForColumn: columnName, occurrence: occurrence)
        }
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
