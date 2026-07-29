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

    func recomputeValueFilteredIDs() {
        let tableRows = tableRowsProvider()
        valueFilterState.prune(againstColumns: tableRows.columns)

        guard valueFilterState.isActive else {
            valueFilteredIDs = nil
            return
        }

        let baseOrder: [RowID] = sortedIDs ?? tableRows.rows.map(\.id)
        var result: [RowID] = []
        result.reserveCapacity(baseOrder.count)
        for id in baseOrder {
            if id.isInserted {
                result.append(id)
                continue
            }
            guard let index = tableRows.index(of: id) else { continue }
            if rowPassesValueFilter(tableRows.rows[index], in: tableRows) {
                result.append(id)
            }
        }
        valueFilteredIDs = result
    }

    private func rowPassesValueFilter(_ row: Row, in tableRows: TableRows) -> Bool {
        for (dataIndex, filter) in valueFilterState.filters {
            guard dataIndex >= 0, dataIndex < row.values.count else { return false }
            let rawValue = row.values[dataIndex]
            if case .null = rawValue {
                if !filter.includesNull { return false }
                continue
            }
            let columnType = dataIndex < tableRows.columnTypes.count ? tableRows.columnTypes[dataIndex] : nil
            let display = displayValue(forID: row.id, column: dataIndex, rawValue: rawValue, columnType: columnType)
                ?? rawValue.asText ?? ""
            if !filter.selectedValues.contains(display) { return false }
        }
        return true
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

    private func reloadAfterValueFilterChange() {
        recomputeValueFilteredIDs()
        updateCache()
        visualIndex.rebuild(from: changeManager, sortedIDs: displayIDs)
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

        activeValueFilterPopover?.close()
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
}
