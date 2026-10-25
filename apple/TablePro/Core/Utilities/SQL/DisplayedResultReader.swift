//
//  DisplayedResultReader.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Filtered display order, hidden and moved columns, no deleted rows: JSON and AppleScript read results through here.
internal enum DisplayedResultReader {
    internal struct Output {
        internal let columns: [String]
        internal let columnTypes: [ColumnType]
        internal let rows: [[PluginCellValue]]
        internal let skippedDeletedCount: Int
    }

    // Empty selectedDisplayIndices means every displayed row.
    internal static func read(
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedDisplayIndices: Set<Int>,
        deletedRowIDs: Set<RowID> = [],
        columns projection: VisibleColumnProjection
    ) -> Output {
        let positions: [Int]
        if selectedDisplayIndices.isEmpty {
            positions = Array(0..<(displayIDs?.count ?? tableRows.rows.count))
        } else {
            positions = selectedDisplayIndices.sorted()
        }

        let order = DataGridRowOrder(filteredIDs: displayIDs, revision: 0)
        var skippedDeleted = 0
        let rows: [[PluginCellValue]] = positions.compactMap { displayIndex in
            guard let row = order.row(at: displayIndex, in: tableRows) else { return nil }
            guard !deletedRowIDs.contains(row.id) else {
                skippedDeleted += 1
                return nil
            }
            return projection.values(Self.values(of: row))
        }

        return Output(
            columns: projection.columns(tableRows.columns),
            columnTypes: projection.columnTypes(tableRows.columnTypes),
            rows: rows,
            skippedDeletedCount: skippedDeleted
        )
    }

    // A value the page left on the server says so, rather than reading as NULL.
    private static func values(of row: Row) -> [PluginCellValue] {
        guard row.hasUnloadedValues else { return Array(row.values) }
        var values = Array(row.values)
        for (column, byteCount) in row.unloadedColumns where values.indices.contains(column) {
            values[column] = .text(UnloadedValueText.notLoaded(byteCount: byteCount))
        }
        return values
    }
}
