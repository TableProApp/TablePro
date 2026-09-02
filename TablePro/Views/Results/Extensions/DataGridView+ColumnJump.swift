//
//  DataGridView+ColumnJump.swift
//  TablePro
//

import AppKit

/// A jump the grid could not perform yet because the column was hidden.
///
/// It carries the data index when the entry had one, because a name alone resolves to the last
/// of two same-named columns; a column a table tab never fetched has no index until it lands, so
/// the name is the fallback. `tableKey` is the table the request was made against, so a preview
/// tab retargeted to another table with a column of the same name does not jump there. A table
/// tab refetches to show a column, so its jump waits for that result to be installed rather than
/// landing on the interim update that unhides an already-fetched key or sort column, which the
/// refetch would then undo; a query tab shows a column without fetching, so it does not wait.
struct PendingColumnJump: Equatable {
    let name: String
    let dataIndex: Int?
    let tableKey: ColumnLayoutTableKey?
    let awaitsResultReplacement: Bool
}

extension TableViewCoordinator {
    /// The data index under the cell cursor, or nil while the cursor sits on chrome or nowhere.
    var focusedDataColumnIndex: Int? {
        guard let tableView = tableView as? KeyHandlingTableView,
              presentsColumn(atTableColumnIndex: tableView.focusedColumn) else { return nil }
        return dataColumnIndex(from: tableView.tableColumns[tableView.focusedColumn].identifier)
    }

    /// Scrolls a presented column into view and puts the cell cursor in it, on the selected row or
    /// else the first row in the viewport. It goes through `focusCell`, the one way a keystroke
    /// moves the cursor, so the selection, the repaint and the accessibility notice all follow.
    /// A jump that lands supersedes any jump still parked, so an older request cannot take the
    /// cursor back when its column finally arrives.
    @discardableResult
    func jumpToColumn(dataIndex: Int) -> Bool {
        guard let tableView = tableView as? KeyHandlingTableView,
              let tableColumnIndex = tableColumnIndex(for: dataIndex),
              presentsColumn(atTableColumnIndex: tableColumnIndex) else { return false }
        pendingColumnJump = nil
        overlayEditor?.dismiss(commit: true)
        dismissFKPreviewOnColumnChange()
        let row = jumpRow(in: tableView)
        if row >= 0 {
            tableView.focusCell(row: row, column: tableColumnIndex)
        } else {
            scrollColumnToVisible(tableColumnIndex: tableColumnIndex)
        }
        _ = focusGrid()
        return true
    }

    /// Runs the parked jump once the grid's update pass has put the column on screen. Deferred off
    /// the pass itself, because the jump selects a row and that write reaches SwiftUI state.
    func schedulePendingColumnJump(contentReplaced: Bool) {
        guard pendingColumnJump != nil else { return }
        Task { @MainActor [weak self] in
            self?.consumePendingColumnJump(contentReplaced: contentReplaced)
        }
    }

    /// - Parameter contentReplaced: whether this update installed a new result. A request that
    ///   waits for its refetch lands only on one, and a request whose column a new result no
    ///   longer carries is dropped rather than left armed for a result that may never come.
    func consumePendingColumnJump(contentReplaced: Bool) {
        guard let pending = pendingColumnJump else { return }
        guard pending.tableKey == columnLayoutKey else {
            pendingColumnJump = nil
            return
        }
        guard contentReplaced || !pending.awaitsResultReplacement else { return }
        if let dataIndex = resolvedDataIndex(for: pending), jumpToColumn(dataIndex: dataIndex) {
            return
        }
        if contentReplaced {
            pendingColumnJump = nil
        }
    }

    private func resolvedDataIndex(for pending: PendingColumnJump) -> Int? {
        if let dataIndex = pending.dataIndex, identitySchema.columnName(for: dataIndex) == pending.name {
            return dataIndex
        }
        return identitySchema.dataIndex(forColumnName: pending.name)
    }

    private func jumpRow(in tableView: NSTableView) -> Int {
        if tableView.selectedRow >= 0 {
            return tableView.selectedRow
        }
        guard tableView.numberOfRows > 0 else { return -1 }
        return max(0, tableView.rows(in: tableView.visibleRect).location)
    }
}
