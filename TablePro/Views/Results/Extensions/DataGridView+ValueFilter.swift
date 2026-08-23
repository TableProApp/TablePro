//
//  DataGridView+ValueFilter.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

extension TableViewCoordinator {
    func distinctValues(forColumn dataIndex: Int) -> [ColumnDistinctValue] {
        let tableRows = tableRowsProvider()
        guard dataIndex >= 0, dataIndex < tableRows.columns.count else { return [] }
        let columnType = dataIndex < tableRows.columnTypes.count ? tableRows.columnTypes[dataIndex] : nil

        var counts: [String: Int] = [:]
        var order: [String] = []
        var nullCount = 0

        for row in tableRows.rows {
            guard dataIndex < row.values.count else { continue }
            let rawValue = row.values[dataIndex]
            if case .null = rawValue {
                nullCount += 1
                continue
            }
            let display = displayValue(forID: row.id, column: dataIndex, rawValue: rawValue, columnType: columnType)
                ?? rawValue.asText ?? ""
            if counts[display] == nil { order.append(display) }
            counts[display, default: 0] += 1
        }

        var result = order
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ColumnDistinctValue(display: $0, isNull: false, count: counts[$0] ?? 0) }
        if nullCount > 0 {
            result.insert(ColumnDistinctValue(display: "", isNull: true, count: nullCount), at: 0)
        }
        return result
    }

    /// Recomputes what the grid shows, through the same resolver the tab's owner uses.
    ///
    /// Both sides run one pure function over the same rows, filter, formats and database type, so
    /// the grid and the readers that run without it cannot disagree about the display order.
    func recomputeValueFilteredIDs() {
        let tableRows = tableRowsProvider()
        valueFilteredIDs = GridDisplayOrderResolver.resolve(
            tableRows: tableRows,
            valueFilter: valueFilterState,
            displayFormats: columnDisplayFormats,
            databaseType: databaseType
        )
    }

    /// Forgets filters whose column has moved or gone, so the header stops flagging a column that
    /// no longer filters anything.
    ///
    /// Kept separate from `recomputeValueFilteredIDs` because that one runs on every view update
    /// and must not write to the filter's owner, while this one only runs on a wholesale
    /// replacement. The resolver treats a stale entry as inert either way, so a filter that has not
    /// been pruned yet still narrows nothing.
    func pruneStaleValueFilters() {
        guard valueFilterState.isActive else { return }
        var state = valueFilterState
        guard state.prune(againstColumns: tableRowsProvider().columns) else { return }
        valueFilterState = state
    }

    func applyValueFilter(_ filter: ColumnValueFilter?, columnName: String, forColumn dataIndex: Int) {
        if let filter {
            valueFilterState.set(filter, columnName: columnName, forColumn: dataIndex)
        } else {
            valueFilterState.clear(column: dataIndex)
        }
        reloadAfterValueFilterChange()
    }

    func clearAllValueFilters() {
        guard valueFilterState.isActive else { return }
        valueFilterState.clearAll()
        reloadAfterValueFilterChange()
    }

    func reloadAfterValueFilterChange() {
        recomputeValueFilteredIDs()
        updateCache()
        visualIndex.rebuild(from: changeManager, displayIDs: displayIDs)
        selectionController.clear()
        tableView?.reloadData()
        updateValueFilterHeaderIndicators()
        startBackgroundPrewarm()
    }

    func updateValueFilterHeaderIndicators() {
        guard let header = tableView?.headerView as? SortableHeaderView else { return }
        header.updateValueFilterIndicators(activeColumns: valueFilterState.activeColumns)
    }

    func presentValueFilterPopover(forColumn dataIndex: Int, anchor rect: NSRect, in view: NSView) {
        let tableRows = tableRowsProvider()
        guard dataIndex >= 0, dataIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[dataIndex]
        let values = distinctValues(forColumn: dataIndex)
        let initialFilter = valueFilterState.filter(forColumn: dataIndex)
        let loadedRowCount = tableRows.count

        dismissActiveValueFilterPopover()
        activeValueFilterPopover = PopoverPresenter.show(
            relativeTo: rect,
            of: view,
            preferredEdge: .maxY
        ) { [weak self] dismiss in
            ColumnValueFilterPopover(
                columnName: columnName,
                values: values,
                loadedRowCount: loadedRowCount,
                initialFilter: initialFilter,
                onApply: { filter in
                    self?.applyValueFilter(filter, columnName: columnName, forColumn: dataIndex)
                    dismiss()
                },
                onCancel: dismiss
            )
        }
    }

    func dismissActiveValueFilterPopover() {
        guard let popover = activeValueFilterPopover else { return }
        activeValueFilterPopover = nil
        popover.close()
    }

    /// A popover carries the display row and the column index it was opened from, and those are
    /// positions rather than identities: replacing the rows moves a record somewhere else, so a
    /// commit afterwards writes the edit to whichever record now sits at that position. The
    /// distinct values behind the value filter go stale the same way. Closing is the only honest
    /// answer, because there is nothing to re-anchor to once the record has moved.
    func dismissPopoversBoundToDisplayPositions() {
        dismissActiveCellEditorPopover()
        dismissPoppedOutCellEditor()
        dismissActiveValueFilterPopover()
        dismissFKPreviewOnColumnChange()
    }
}
