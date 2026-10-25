//
//  DataTabGridAdapter.swift
//  TablePro
//

import AppKit
import Combine
import TableProPluginKit

@MainActor
final class DataTabGridAdapter: DataGridDataSource, DataGridActions {
    private static let detachedChangeState = AnyChangeManager(DataChangeManager())

    let tabId: UUID
    private weak var coordinator: MainContentCoordinator?
    private weak var model: DataGridModel?
    private let sqlExporter: DataTabSQLExporter
    var pendingColumnJump: ColumnJumpRequest?

    init(tabId: UUID, coordinator: MainContentCoordinator) {
        self.tabId = tabId
        self.coordinator = coordinator
        self.sqlExporter = DataTabSQLExporter(tabId: tabId, coordinator: coordinator)
    }

    // A refresh deferred while a cell was open runs once the edit ends, committed, cancelled or unchanged, on the
    // next turn, as after a commit, so the editor finishes tearing down first.
    func attach(_ model: DataGridModel) {
        self.model = model
        model.onEditingEnded = { [weak coordinator] in
            Task { @MainActor [weak coordinator] in
                coordinator?.resumeDeferredTableRefresh()
            }
        }
    }

    private var tab: QueryTab? {
        coordinator?.tabManager.tabs.first { $0.id == tabId }
    }

    // The change manager and the window's row commands belong to the selected tab only.
    private var ownsWindowState: Bool {
        coordinator?.changeManagerTabId == tabId
    }

    // MARK: - DataGridDataSource

    var gridRows: TableRows {
        coordinator?.tabSessionRegistry.existingTableRows(for: tabId) ?? TableRows()
    }

    var gridChangeState: AnyChangeManager {
        coordinator?.gridChangeState ?? Self.detachedChangeState
    }

    var gridRowNumberOffset: Int {
        tab?.pagination.currentOffset ?? 0
    }

    var gridHasUnloadedRows: Bool {
        guard let tab else { return false }
        return tab.pagination.hasUnloadedRows(loadedRowCount: gridRows.rows.count)
    }

    var gridHighlightRules: [HighlightRule] {
        guard let coordinator, let tab else { return [] }
        return coordinator.highlightRules(for: tab)
    }

    // MARK: - Edits

    // A commit against a tab the shared change manager no longer holds would land in another table (H2).
    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        guard let coordinator, ownsWindowState else { return false }
        let committed = coordinator.rowEditingCoordinator.commitGridEdits(edits, actionName: actionName, tabId: tabId)
        if committed {
            coordinator.gridCellsEdited.send()
            Task { @MainActor [weak coordinator] in
                coordinator?.resumeDeferredTableRefresh()
            }
        }
        return committed
    }

    func gridDeleteRows(_ rowIDs: [RowID]) {
        guard ownsWindowState else { return }
        coordinator?.deleteRows(rowIDs)
    }

    // The window's own copy, whose paste payload carries staged SQL, as Copy Rows always was here.
    func gridCopyRows(_ rowIDs: [RowID]) -> Bool {
        guard let coordinator, ownsWindowState, !rowIDs.isEmpty else { return false }
        coordinator.copyRowsToClipboard(rowIDs)
        return true
    }

    func gridUndoDelete(_ rowIDs: [RowID]) {
        guard ownsWindowState else { return }
        coordinator?.undoRowDeletions(rowIDs)
    }

    func gridAddRow() {
        guard ownsWindowState else { return }
        coordinator?.addNewRow()
    }

    func gridDuplicateRows(_ rowIDs: [RowID]) {
        guard ownsWindowState, let first = rowIDs.first else { return }
        coordinator?.duplicateRow(first)
    }

    func gridCanPasteRows() -> Bool {
        ownsWindowState && (coordinator?.commandActions?.canPasteRows ?? false)
    }

    func gridPasteRows() {
        guard ownsWindowState else { return }
        coordinator?.pasteRows()
    }

    func gridLoadUnloadedValues(
        rowIDs: [RowID],
        columns: IndexSet?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let coordinator else {
            completion(false)
            return
        }
        let tabId = tabId
        Task { @MainActor in
            completion(await coordinator.loadUnloadedValues(tabId: tabId, rowIDs: rowIDs, columns: columns))
        }
    }

    // MARK: - Display order

    // The gate sort, pagination and the WHERE filter take; it answers at once when nothing would be lost.
    func gridConfirmDisplayOrderChange(then apply: @escaping @MainActor () -> Void) {
        guard let coordinator else {
            apply()
            return
        }
        coordinator.confirmDiscardRestoringRowsIfNeeded(action: .displayOrder) { confirmed in
            guard confirmed else { return }
            apply()
        }
    }

    // MARK: - Columns

    func gridFilterWithColumn(_ column: DataGridColumn) {
        guard ownsWindowState else { return }
        coordinator?.addFilterForColumn(column.name)
    }

    func gridHideColumn(_ column: DataGridColumn) {
        guard ownsWindowState else { return }
        coordinator?.hideColumn(column.name)
    }

    func gridShowAllColumns() {
        guard ownsWindowState else { return }
        coordinator?.showAllColumns()
    }

    // MARK: - Navigation and results

    func gridNavigateForeignKey(value: String, info: ForeignKeyInfo, intent: ReferenceOpenIntent) {
        coordinator?.navigateToFKReference(value: value, fkInfo: info, intent: intent)
    }

    // The inspector shows the selection, so rows the menu was opened on outside it become the selection.
    func gridShowRowsAsJSON(_ rowIDs: [RowID]) {
        guard ownsWindowState else { return }
        if let model, !rowIDs.isEmpty, Set(model.selectedRowIDs) != Set(rowIDs) {
            model.selectRows(rowIDs)
        }
        coordinator?.showRowAsJSON()
    }

    func gridExportResults() {
        AppCommands.shared.exportQueryResults.send(())
    }

    func gridClearResults() {
        guard ownsWindowState else { return }
        coordinator?.clearActiveQueryResults()
    }

    func gridSearchAllRows(term: String) {
        coordinator?.findCoordinator.searchAllRows(term: term, tabID: tabId)
    }

    var gridSQLExporter: (any DataGridSQLExporting)? {
        sqlExporter
    }

    // MARK: - Menus

    func gridRowMenuItems(for rowIDs: [RowID], clickedRow: RowID) -> [NSMenuItem] {
        guard let coordinator, ownsWindowState, coordinator.canInsertDocument else { return [] }
        var items: [NSMenuItem] = []
        // Read while the menu is built, so a reload under the open menu cannot retarget the edit.
        if rowIDs.count == 1, let rowID = rowIDs.first, let locator = coordinator.documentLocator(for: rowID) {
            items.append(ClosureMenuTarget.item(title: String(localized: "Edit Document…")) { [weak coordinator] in
                coordinator?.presentEditDocument(locator: locator)
            })
        }
        items.append(ClosureMenuTarget.item(title: String(localized: "Insert Document…")) { [weak coordinator] in
            coordinator?.presentInsertDocument()
        })
        return items
    }

    func gridCellMenuItems(for rowID: RowID, column: DataGridColumn) -> [NSMenuItem] {
        guard let coordinator, ownsWindowState else { return [] }
        let rows = gridRows
        guard let row = rows.row(withID: rowID), column.dataIndex < row.values.count else { return [] }
        var items: [NSMenuItem] = []
        if let filterItem = filterMenuItem(row: row, column: column, in: rows, coordinator: coordinator) {
            items.append(filterItem)
        }
        if let highlightItem = highlightMenuItem(row: row, column: column, in: rows, coordinator: coordinator) {
            items.append(highlightItem)
        }
        return items
    }

    // Only a value the server holds: a filter built from an inserted row or an edited cell finds nothing.
    private func filterMenuItem(
        row: Row,
        column: DataGridColumn,
        in rows: TableRows,
        coordinator: MainContentCoordinator
    ) -> NSMenuItem? {
        guard coordinator.canFilterRows,
              !row.id.isInserted,
              !coordinator.changeManager.isCellModified(rowID: row.id, columnIndex: column.dataIndex) else { return nil }
        let tabId = tabId
        return CellFilterMenuBuilder.menuItem(
            columnName: column.name,
            columnType: column.type,
            value: row.values[column.dataIndex],
            family: SQLTypeFamily.of(coordinator.connection.type)
        ) { [weak coordinator] filter in
            coordinator?.applyCellFilter(filter, forTab: tabId)
        }
    }

    private func highlightMenuItem(
        row: Row,
        column: DataGridColumn,
        in rows: TableRows,
        coordinator: MainContentCoordinator
    ) -> NSMenuItem? {
        guard let tab else { return nil }
        let tabId = tabId
        let context = HighlightMenuBuilder.CellContext(
            columnName: column.name,
            columnOccurrence: HighlightRuleSet.occurrence(ofColumnAt: column.dataIndex, in: rows.columns),
            columnType: column.type,
            value: row.values[column.dataIndex],
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

    func gridEmptySpaceMenu() -> NSMenu? {
        guard let coordinator, ownsWindowState else { return nil }
        var items: [NSMenuItem] = []
        if coordinator.canAddRow {
            items.append(ClosureMenuTarget.item(title: String(localized: "Add Row")) { [weak coordinator] in
                coordinator?.addNewRow()
            })
        }
        if coordinator.canInsertDocument {
            items.append(ClosureMenuTarget.item(title: String(localized: "Insert Document…")) { [weak coordinator] in
                coordinator?.presentInsertDocument()
            })
        }
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        return menu
    }

    func gridHighlightValuesMenuItem(for column: DataGridColumn) -> NSMenuItem? {
        guard let coordinator, ownsWindowState else { return nil }
        let occurrence = HighlightRuleSet.occurrence(ofColumnAt: column.dataIndex, in: gridRows.columns)
        let name = column.name
        return ClosureMenuTarget.item(title: String(localized: "Highlight Values…")) { [weak coordinator] in
            coordinator?.presentHighlightRules(addingRuleForColumn: name, occurrence: occurrence)
        }
    }
}

// A jump to a column the result does not present yet, landed once the column arrives.
struct ColumnJumpRequest: Equatable {
    let name: String
    let dataIndex: Int?
    let tableKey: ColumnLayoutTableKey?
    // A table tab fetches a column to show it, so its jump waits for that result rather than an interim update.
    let awaitsResultReplacement: Bool
}
