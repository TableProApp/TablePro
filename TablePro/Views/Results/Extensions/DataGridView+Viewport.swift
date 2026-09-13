//
//  DataGridView+Viewport.swift
//  TablePro
//

import AppKit
import Foundation

internal struct GridViewportSample: Equatable {
    let firstVisibleRow: Int
    let offset: CGFloat
}

extension TableViewCoordinator {
    func viewportSample() -> GridViewportSample? {
        guard let tableView, tableView.numberOfRows > 0 else { return nil }
        let visibleRect = unobscuredVisibleRect(of: tableView)
        let visibleRows = tableView.rows(in: visibleRect)
        guard visibleRows.length > 0, visibleRows.location < tableView.numberOfRows else { return nil }
        let offset = visibleRect.minY - tableView.rect(ofRow: visibleRows.location).minY
        return GridViewportSample(firstVisibleRow: visibleRows.location, offset: max(0, offset))
    }

    func applyViewportPlacement(_ placement: GridViewportPlacement) {
        guard let tableView, tableView.numberOfRows > 0 else { return }
        let tableRows = tableRowsProvider()
        scrollFirstVisibleRow(of: placement, in: tableView, tableRows: tableRows)

        let selectedRows = displayRows(for: placement.selectedRows, in: tableRows, rowLimit: tableView.numberOfRows)
        guard !selectedRows.isEmpty else { return }
        selectDisplayRows(selectedRows, in: tableView)

        guard placement.revealsSelection, let firstSelectedRow = selectedRows.first else { return }
        tableView.scrollRowToVisible(firstSelectedRow)
    }

    func selectedRowIDs() -> [RowID] {
        guard let tableView else { return [] }
        let tableRows = tableRowsProvider()
        return tableView.selectedRowIndexes.compactMap { displayRow(at: $0, in: tableRows)?.id }
    }

    func reselectRows(_ rowIDs: [RowID]) {
        guard let tableView, !rowIDs.isEmpty else { return }
        let rows = displayRows(for: rowIDs, in: tableRowsProvider(), rowLimit: tableView.numberOfRows)
        guard !rows.isEmpty else { return }
        selectDisplayRows(rows, in: tableView)
    }

    private func scrollFirstVisibleRow(
        of placement: GridViewportPlacement,
        in tableView: NSTableView,
        tableRows: TableRows
    ) {
        let topInset = headerInset(of: tableView)
        let horizontalOffset = tableView.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        guard let rowID = placement.firstVisibleRow,
              let displayRow = DisplayRowMapping.displayIndex(forRowID: rowID, displayIDs: displayIDs, in: tableRows),
              displayRow < tableView.numberOfRows else {
            tableView.scroll(NSPoint(x: horizontalOffset, y: -topInset))
            return
        }
        let rowOrigin = tableView.rect(ofRow: displayRow).minY
        tableView.scroll(NSPoint(x: horizontalOffset, y: rowOrigin + placement.firstVisibleOffset - topInset))
    }

    private func headerInset(of tableView: NSTableView) -> CGFloat {
        tableView.enclosingScrollView?.contentView.contentInsets.top ?? 0
    }

    private func unobscuredVisibleRect(of tableView: NSTableView) -> NSRect {
        let topInset = headerInset(of: tableView)
        var rect = tableView.visibleRect
        rect.origin.y += topInset
        rect.size.height = max(0, rect.size.height - topInset)
        return rect
    }

    private func displayRows(for rowIDs: [RowID], in tableRows: TableRows, rowLimit: Int) -> IndexSet {
        IndexSet(
            rowIDs
                .compactMap { DisplayRowMapping.displayIndex(forRowID: $0, displayIDs: displayIDs, in: tableRows) }
                .filter { $0 < rowLimit }
        )
    }

    private func selectDisplayRows(_ rows: IndexSet, in tableView: NSTableView) {
        selectionController.clear()
        selectRowsProgrammatically(rows, in: tableView)
        publishRowSelection(rowSelection: Set(rows))
    }
}
