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
///
/// They part company on pending deletions, because they answer different questions. The JSON view
/// shows what a Save would leave behind, so it excludes rows marked for deletion; a JSON document
/// has no way to mark one, and leaving it in is what made a delete look like it did nothing. Copy
/// as JSON copies the rows you selected, the same as every other Copy as, so it passes no deletions
/// and keeps them all.
internal enum ResultJsonSerializer {
    internal struct Output {
        let json: String
        let rowCount: Int
        /// How many rows were left out because they are marked for deletion. Counted here rather
        /// than derived by the caller, so the disclosure can never claim a row was held back that
        /// was not in the document to begin with.
        let skippedDeletedCount: Int
    }

    /// - Parameter selectedDisplayIndices: display positions to narrow to. Empty means every
    ///   displayed row, which is what an untouched result set shows.
    /// - Parameter deletedDisplayIndices: display positions marked for deletion but not yet saved.
    ///   Empty, the default, serialises every row.
    internal static func serialize(
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedDisplayIndices: Set<Int>,
        deletedDisplayIndices: Set<Int> = [],
        columns projection: VisibleColumnProjection
    ) -> Output {
        let read = DisplayedResultReader.read(
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: selectedDisplayIndices,
            deletedDisplayIndices: deletedDisplayIndices,
            columns: projection
        )

        let converter = JsonRowConverter(columns: read.columns, columnTypes: read.columnTypes)
        return Output(
            json: converter.generateJson(rows: read.rows),
            rowCount: read.rows.count,
            skippedDeletedCount: read.skippedDeletedCount
        )
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
