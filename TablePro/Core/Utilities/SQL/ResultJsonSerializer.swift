//
//  ResultJsonSerializer.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The one place a result set becomes JSON.
///
/// The results pane's JSON view and the grid's Copy as JSON render the same rows, so they share
/// this rather than each deciding for itself which rows and columns to include. Both follow the
/// grid as shown: display order, no hidden columns, current column order.
internal enum ResultJsonSerializer {
    internal struct Output {
        let json: String
        let rowCount: Int
    }

    /// - Parameter selectedDisplayIndices: display positions to narrow to. Empty means every
    ///   displayed row, which is what an untouched result set shows.
    internal static func serialize(
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedDisplayIndices: Set<Int>,
        columns projection: VisibleColumnProjection
    ) -> Output {
        let positions: [Int]
        if selectedDisplayIndices.isEmpty {
            positions = Array(0..<(displayIDs?.count ?? tableRows.rows.count))
        } else {
            positions = selectedDisplayIndices.sorted()
        }

        let rows: [[PluginCellValue]] = positions.compactMap { displayIndex in
            DisplayRowMapping.row(forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows)
                .map { projection.values(Array($0.values)) }
        }

        let converter = JsonRowConverter(
            columns: projection.columns(tableRows.columns),
            columnTypes: projection.columnTypes(tableRows.columnTypes)
        )
        return Output(json: converter.generateJson(rows: rows), rowCount: rows.count)
    }
}

internal extension VisibleColumnProjection {
    /// Builds a projection from the layout the user arranged in the grid.
    ///
    /// Reads the persisted layout rather than the live `NSTableView` columns, because the grid is
    /// not mounted while the results pane is showing JSON. Duplicate column names cannot be mapped
    /// back to a single index, so a result with duplicates keeps every column.
    static func fromColumnLayout(_ layout: ColumnLayoutState, columns: [String]) -> VisibleColumnProjection {
        guard Set(columns).count == columns.count else { return .identity }
        guard !layout.hiddenColumns.isEmpty || layout.columnOrder != nil else { return .identity }

        let ordered: [String]
        if let columnOrder = layout.columnOrder {
            let known = columnOrder.filter { columns.contains($0) }
            ordered = known + columns.filter { !known.contains($0) }
        } else {
            ordered = columns
        }

        let indices = ordered.compactMap { name -> Int? in
            guard !layout.hiddenColumns.contains(name) else { return nil }
            return columns.firstIndex(of: name)
        }
        return VisibleColumnProjection(indices: indices)
    }
}
