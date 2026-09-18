//
//  GridDisplayOrderResolver.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Turns a per-column value filter into the order the grid displays.
///
/// Pure, so both the grid and the coordinator that has to answer while the grid is unmounted can
/// call it and cannot disagree. Matching is done on the displayed string rather than the raw value,
/// because that is what the filter popover offered the user to pick from.
@MainActor
internal enum GridDisplayOrderResolver {
    /// - Returns: the displayed row ids, or nil when no filter is active and the display order is
    ///   the storage order.
    internal static func resolve(
        tableRows: TableRows,
        valueFilter: GridValueFilterState,
        displayFormats: [ValueDisplayFormat?],
        databaseType: DatabaseType?
    ) -> [RowID]? {
        let active = activeFilters(valueFilter, columns: tableRows.columns)
        guard !active.isEmpty else { return nil }

        var result: [RowID] = []
        result.reserveCapacity(tableRows.rows.count)
        for row in tableRows.rows {
            if row.id.isInserted {
                result.append(row.id)
                continue
            }
            if passes(row, filters: active, tableRows: tableRows, displayFormats: displayFormats, databaseType: databaseType) {
                result.append(row.id)
            }
        }
        return result
    }

    /// The displayed form of a cell, which is what a value filter stores and matches against.
    internal static func displayValue(
        _ rawValue: PluginCellValue,
        columnType: ColumnType?,
        displayFormat: ValueDisplayFormat?,
        databaseType: DatabaseType?
    ) -> String {
        CellDisplayFormatter.format(
            rawValue,
            columnType: columnType,
            displayFormat: displayFormat,
            databaseType: databaseType
        ) ?? rawValue.asText ?? ""
    }

    /// Drops filters whose column has moved or disappeared since they were set.
    ///
    /// A filter is keyed by column index and remembers the name it was set on, so a result set of a
    /// different shape would otherwise apply one column's chosen values to another column's cells.
    /// Reading it out rather than mutating keeps this callable from a getter; the mutating
    /// `GridValueFilterState.prune` still tidies the stored state at the points that replace rows.
    private static func activeFilters(
        _ valueFilter: GridValueFilterState,
        columns: [String]
    ) -> [(dataIndex: Int, filter: ColumnValueFilter)] {
        valueFilter.filters.compactMap { dataIndex, filter in
            guard dataIndex >= 0, dataIndex < columns.count else { return nil }
            guard valueFilter.columnName(forColumn: dataIndex) == columns[dataIndex] else { return nil }
            return (dataIndex: dataIndex, filter: filter)
        }
    }

    private static func passes(
        _ row: Row,
        filters: [(dataIndex: Int, filter: ColumnValueFilter)],
        tableRows: TableRows,
        displayFormats: [ValueDisplayFormat?],
        databaseType: DatabaseType?
    ) -> Bool {
        for (dataIndex, filter) in filters {
            guard dataIndex < row.values.count else { return false }
            let rawValue = row.values[dataIndex]
            if case .null = rawValue {
                if !filter.includesNull { return false }
                continue
            }
            let columnType = dataIndex < tableRows.columnTypes.count ? tableRows.columnTypes[dataIndex] : nil
            let format = dataIndex < displayFormats.count ? displayFormats[dataIndex] : nil
            let display = displayValue(
                rawValue,
                columnType: columnType,
                displayFormat: format,
                databaseType: databaseType
            )
            if !filter.selectedValues.contains(display) { return false }
        }
        return true
    }
}
