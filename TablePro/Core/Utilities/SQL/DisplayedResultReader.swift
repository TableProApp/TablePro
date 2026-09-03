//
//  DisplayedResultReader.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The rows a result tab is showing, in the order it is showing them.
///
/// Anything that reads a result outside the grid itself has to answer the same three questions, and
/// get all three right: display positions are not storage indices once a value filter is on, hidden
/// and reordered columns are the reader's business too, and a row marked for deletion is in the
/// buffer but not in the result. `ResultJsonSerializer` answered them for JSON; AppleScript needs
/// the same answers as values, so they live here and JSON is one encoding of the output.
internal enum DisplayedResultReader {
    internal struct Output {
        internal let columns: [String]
        internal let columnTypes: [ColumnType]
        internal let rows: [[PluginCellValue]]
        /// How many rows were left out because they are marked for deletion.
        internal let skippedDeletedCount: Int
    }

    /// - Parameter selectedDisplayIndices: display positions to narrow to. Empty means every
    ///   displayed row, which is what an untouched result set shows.
    /// - Parameter deletedDisplayIndices: display positions marked for deletion but not yet saved.
    ///   Empty, the default, reads every row.
    internal static func read(
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedDisplayIndices: Set<Int>,
        deletedDisplayIndices: Set<Int> = [],
        columns projection: VisibleColumnProjection
    ) -> Output {
        let positions: [Int]
        if selectedDisplayIndices.isEmpty {
            positions = Array(0..<(displayIDs?.count ?? tableRows.rows.count))
        } else {
            positions = selectedDisplayIndices.sorted()
        }

        var skippedDeleted = 0
        let rows: [[PluginCellValue]] = positions.compactMap { displayIndex in
            guard let row = DisplayRowMapping.row(
                forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows
            ) else { return nil }
            guard !deletedDisplayIndices.contains(displayIndex) else {
                skippedDeleted += 1
                return nil
            }
            return projection.values(Array(row.values))
        }

        return Output(
            columns: projection.columns(tableRows.columns),
            columnTypes: projection.columnTypes(tableRows.columnTypes),
            rows: rows,
            skippedDeletedCount: skippedDeleted
        )
    }
}
