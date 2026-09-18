//
//  MainContentCoordinator+ColumnJump.swift
//  TablePro
//

import AppKit
import Foundation

/// Where a Jump to Column panel was opened from. A menu command can switch the tab under the
/// panel before Return, and a commit that resolved the tab at that moment would jump to the same
/// index in an unrelated result, so the commit is checked against the origin instead.
struct ColumnJumpOrigin {
    let tabId: UUID
    weak var grid: TableViewCoordinator?
}

extension MainContentCoordinator {
    static let columnJumpPanelIdentity = "column-jump"

    /// The one column list the Columns popover and Jump to Column both read, so hiding and
    /// jumping never disagree about what the result holds.
    func columnCatalog(for tab: QueryTab, resultRows: TableRows) -> [GridColumnEntry] {
        let mountedGrid = tab.id == tabManager.selectedTabId ? dataTabDelegate?.tableViewCoordinator : nil
        return GridColumnCatalog.entries(
            resultColumns: resultRows.columns,
            columnTypes: resultRows.columnTypes,
            hiddenColumns: tab.columnLayout.hiddenColumns,
            displayOrder: mountedGrid?.visibleColumnDataIndices(),
            pickerColumns: columnsForVisibilityPicker(for: tab, resultColumns: resultRows.columns)
        )
    }

    /// Whether the selected tab has a data grid on screen to jump in. A query result with no rows
    /// shows an empty-result view instead of a grid, and a collapsed results pane hides it, so the
    /// grid's own attachment is the fact, not the view mode.
    var hasMountedDataGrid: Bool {
        guard let tab = tabManager.selectedTab, !tab.display.isResultsCollapsed,
              let grid = dataTabDelegate?.tableViewCoordinator else { return false }
        return grid.tableView?.window != nil
    }

    /// Invoking the command while its own panel is up closes it, the way Open Quickly toggles.
    /// An Open Quickly panel is replaced rather than closed: the reader asked for columns.
    func showColumnJump(seededWith query: String = "") {
        guard let quickSwitcherPanel else { return }
        guard !quickSwitcherPanel.isPresenting(Self.columnJumpPanelIdentity) else {
            quickSwitcherPanel.dismiss()
            return
        }
        guard hasMountedDataGrid, let tab = tabManager.selectedTab,
              let grid = dataTabDelegate?.tableViewCoordinator else { return }
        let resultRows = tabSessionRegistry.existingTableRows(for: tab.id) ?? TableRows()
        let entries = columnCatalog(for: tab, resultRows: resultRows)
        guard !entries.isEmpty else { return }

        let origin = ColumnJumpOrigin(tabId: tab.id, grid: grid)
        let panelView = ColumnJumpPanelView(
            entries: entries,
            initialQuery: query,
            cursorColumnIndex: grid.focusedDataColumnIndex,
            onCommit: { [weak self] entry in
                self?.quickSwitcherPanel?.dismiss()
                self?.jumpToColumn(entry, from: origin)
            }
        )
        quickSwitcherPanel.present(panelView, over: contentWindow, identity: Self.columnJumpPanelIdentity)
    }

    /// A hidden column has to be shown before it can be reached, and on a table tab showing it
    /// means fetching it, so the jump is parked on the grid and lands once the column is presented.
    ///
    /// The entry was listed against the result the panel opened over. A result-set switch or a
    /// re-run in the same tab keeps the tab and the grid and replaces the columns, so an index is
    /// trusted only while the column at it still carries the entry's name.
    func jumpToColumn(_ entry: GridColumnEntry, from origin: ColumnJumpOrigin) {
        guard hasMountedDataGrid,
              let tab = tabManager.selectedTab, tab.id == origin.tabId,
              let grid = origin.grid,
              dataTabDelegate?.tableViewCoordinator === grid else { return }
        if entry.isHidden {
            guard tab.columnLayout.hiddenColumns.contains(entry.name) else { return }
            grid.pendingColumnJump = PendingColumnJump(
                name: entry.name,
                dataIndex: entry.dataIndex,
                tableKey: grid.columnLayoutKey,
                awaitsResultReplacement: tab.tabType == .table
            )
            showColumn(entry.name)
            return
        }
        guard let dataIndex = entry.dataIndex,
              grid.identitySchema.columnName(for: dataIndex) == entry.name else { return }
        grid.jumpToColumn(dataIndex: dataIndex)
    }
}
