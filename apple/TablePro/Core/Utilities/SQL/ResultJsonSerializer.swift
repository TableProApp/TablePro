import Foundation
import TableProPluginKit

// The JSON view and Copy as JSON render the same rows, as the grid shows them: display order, no hidden columns,
// current column order. The view leaves out rows marked for deletion, since it shows what a Save leaves behind and a
// document cannot mark a row; Copy as JSON passes no deletions, like every other Copy as.
internal enum ResultJsonSerializer {
    internal struct Output {
        let json: String
        // Rows in the document, which stops at `JsonRowConverter.maxRows`.
        let rowCount: Int
        // Counted here, so the disclosure never names a row that was not in the document to begin with.
        let skippedDeletedCount: Int
        // The converter writes the two-space layout itself. Only a JSON column's raw text, or a row with no columns
        // (written `{` and `}` on two lines), can differ from it.
        let isIndented: Bool
    }

    // Empty selectedDisplayIndices means every displayed row; empty deletedRowIDs keeps every row.
    internal static func serialize(
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedDisplayIndices: Set<Int>,
        deletedRowIDs: Set<RowID> = [],
        defaultedCells: [RowID: Set<Int>] = [:],
        columns projection: VisibleColumnProjection,
        isCancelled: () -> Bool = { false }
    ) -> Output {
        let read = DisplayedResultReader.read(
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: selectedDisplayIndices,
            deletedRowIDs: deletedRowIDs,
            defaultedCells: defaultedCells,
            columns: projection
        )

        let converter = JsonRowConverter(columns: read.columns, columnTypes: read.columnTypes)
        return Output(
            json: converter.generateJson(rows: read.rows, isCancelled: isCancelled),
            rowCount: min(read.rows.count, JsonRowConverter.maxRows),
            skippedDeletedCount: read.skippedDeletedCount,
            isIndented: !read.columns.isEmpty && !read.columnTypes.contains { $0.isJsonType }
        )
    }
}

internal extension VisibleColumnProjection {
    // From the saved layout, not the live columns: the grid is not mounted while the pane shows JSON. Duplicate names
    // cannot map back to one index, so a result with duplicates keeps every column.
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
