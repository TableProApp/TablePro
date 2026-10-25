//
//  MainContentCoordinator+ColumnJump.swift
//  TablePro
//

import AppKit
import Foundation

// Where a Jump to Column panel was opened. A menu command can switch the tab under the panel before
// Return, so the commit is checked against the origin rather than resolved at that moment.
struct ColumnJumpOrigin {
    let tabId: UUID
    weak var model: DataGridModel?
}

extension MainContentCoordinator {
    static let columnJumpPanelIdentity = "column-jump"

    // The one column list the Columns popover and Jump to Column both read.
    func columnCatalog(for tab: QueryTab, resultRows: TableRows) -> [GridColumnEntry] {
        GridColumnCatalog.entries(
            resultColumns: resultRows.columns,
            columnTypes: resultRows.columnTypes,
            hiddenColumns: tab.columnLayout.hiddenColumns,
            displayOrder: existingGridModel(forTab: tab.id)?.columns.columns.map(\.dataIndex),
            pickerColumns: columnsForVisibilityPicker(for: tab, resultColumns: resultRows.columns)
        )
    }

    // A query with no rows shows an empty-result view and a collapsed pane hides the grid, so the mount decides.
    var hasMountedDataGrid: Bool {
        guard let tab = tabManager.selectedTab, !tab.display.isResultsCollapsed else { return false }
        return existingGridModel(forTab: tab.id)?.isMounted == true
    }

    // The command closes its own panel, the way Open Quickly toggles; an Open Quickly panel is replaced.
    func showColumnJump(seededWith query: String = "") {
        guard let quickSwitcherPanel else { return }
        guard !quickSwitcherPanel.isPresenting(Self.columnJumpPanelIdentity) else {
            quickSwitcherPanel.dismiss()
            return
        }
        guard hasMountedDataGrid, let tab = tabManager.selectedTab,
              let model = existingGridModel(forTab: tab.id) else { return }
        let resultRows = tabSessionRegistry.existingTableRows(for: tab.id) ?? TableRows()
        let entries = columnCatalog(for: tab, resultRows: resultRows)
        guard !entries.isEmpty else { return }

        let origin = ColumnJumpOrigin(tabId: tab.id, model: model)
        let panelView = ColumnJumpPanelView(
            entries: entries,
            initialQuery: query,
            cursorColumnIndex: model.activeCell?.column.dataIndex,
            onCommit: { [weak self] entry in
                self?.quickSwitcherPanel?.dismiss()
                self?.jumpToColumn(entry, from: origin)
            }
        )
        quickSwitcherPanel.present(panelView, over: contentWindow, identity: Self.columnJumpPanelIdentity)
    }

    // A hidden column is shown first, which on a table tab means fetching it, so the jump waits for it.
    // An index is trusted only while the column at it still carries the entry's name.
    func jumpToColumn(_ entry: GridColumnEntry, from origin: ColumnJumpOrigin) {
        guard hasMountedDataGrid,
              let tab = tabManager.selectedTab, tab.id == origin.tabId,
              let model = origin.model,
              existingGridModel(forTab: tab.id) === model else { return }
        if entry.isHidden {
            guard tab.columnLayout.hiddenColumns.contains(entry.name) else { return }
            dataGridEntries[tab.id]?.adapter.pendingColumnJump = ColumnJumpRequest(
                name: entry.name,
                dataIndex: entry.dataIndex,
                tableKey: columnLayoutTableKey(for: tab),
                awaitsResultReplacement: tab.tabType == .table
            )
            showColumn(entry.name)
            return
        }
        let columns = model.rows.columns
        guard let dataIndex = entry.dataIndex,
              columns.indices.contains(dataIndex),
              columns[dataIndex] == entry.name else { return }
        jumpToColumn(dataIndex: dataIndex, in: model, tabId: tab.id)
    }

    // Puts the active cell in the column on the active row, or the first visible row, and scrolls it into view.
    @discardableResult
    private func jumpToColumn(dataIndex: Int, in model: DataGridModel, tabId: UUID) -> Bool {
        guard let displayColumn = model.columns.displayPosition(ofDataIndex: dataIndex),
              let column = model.columns.column(at: displayColumn) else { return false }
        dataGridEntries[tabId]?.adapter.pendingColumnJump = nil
        model.commitEditing()
        let row = model.selection.activeCell?.row
            ?? model.selection.affectedRows.first
            ?? model.viewportSample()?.row
            ?? 0
        if let rowID = model.rowID(at: row) {
            model.selectCell(GridCoord(row: row, displayColumn: displayColumn))
            model.reveal(rowID: rowID, columnID: column.id)
        } else {
            model.revealColumn(column.id)
        }
        model.focus()
        return true
    }

    // A request waiting for its refetch lands only on a new result, and one whose column that result
    // does not carry is dropped rather than left armed.
    func consumePendingColumnJump(forTab tabId: UUID, contentReplaced: Bool) {
        guard let entry = dataGridEntries[tabId],
              let pending = entry.adapter.pendingColumnJump,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        guard pending.tableKey == columnLayoutTableKey(for: tab) else {
            entry.adapter.pendingColumnJump = nil
            return
        }
        guard contentReplaced || !pending.awaitsResultReplacement else { return }
        let columns = entry.model.rows.columns
        let dataIndex = pending.dataIndex.flatMap { index in
            columns.indices.contains(index) && columns[index] == pending.name ? index : nil
        } ?? columns.firstIndex(of: pending.name)
        if let dataIndex, jumpToColumn(dataIndex: dataIndex, in: entry.model, tabId: tabId) {
            return
        }
        if contentReplaced {
            entry.adapter.pendingColumnJump = nil
        }
    }
}
