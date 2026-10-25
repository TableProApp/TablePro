import Foundation

// GridSelection names display positions; this survives reloads, filters, reorders and remounts.
struct GridSelectionSnapshot: Equatable {
    struct Cell: Hashable {
        let rowID: RowID
        let columnID: DataGridColumnID
    }

    var rowIDs: [RowID]
    var rectangles: [Rectangle]
    var activeCell: Cell?
    var anchor: Cell?
    var pickedColumnIDs: [DataGridColumnID] = []
    var mode: GridSelection.Mode = .cells

    struct Rectangle: Hashable {
        let rowIDs: [RowID]
        let columnIDs: [DataGridColumnID]
    }

    static let empty = GridSelectionSnapshot(rowIDs: [], rectangles: [], activeCell: nil, anchor: nil)

    var isEmpty: Bool { rowIDs.isEmpty && activeCell == nil }

    // Rows named without rectangles are whole rows.
    init(rowIDs: [RowID], rectangles: [Rectangle], activeCell: Cell?, anchor: Cell?) {
        self.rowIDs = rowIDs
        self.rectangles = rectangles
        self.activeCell = activeCell
        self.anchor = anchor
        self.mode = rectangles.isEmpty && !rowIDs.isEmpty ? .rows : .cells
    }

    init(
        _ selection: GridSelection,
        order: DataGridRowOrder,
        rows: TableRows,
        columns: DataGridColumnSet
    ) {
        func cell(_ coord: GridCoord?) -> Cell? {
            guard let coord,
                  let rowID = order.rowID(at: coord.row, in: rows),
                  let column = columns.column(at: coord.displayColumn) else { return nil }
            return Cell(rowID: rowID, columnID: column.id)
        }
        self.rowIDs = order.rowIDs(atDisplayIndexes: selection.affectedRows, in: rows)
        self.rectangles = selection.rectangles.map { rect in
            Rectangle(
                rowIDs: rect.rows.compactMap { order.rowID(at: $0, in: rows) },
                columnIDs: rect.columns.compactMap { columns.column(at: $0)?.id }
            )
        }
        self.activeCell = cell(selection.activeCell)
        self.anchor = cell(selection.anchor)
        self.pickedColumnIDs = selection.columns.compactMap { columns.column(at: $0)?.id }
        self.mode = selection.mode
    }

    func resolved(order: DataGridRowOrder, rows: TableRows, columns: DataGridColumnSet) -> GridSelection {
        func coord(_ cell: Cell?) -> GridCoord? {
            guard let cell,
                  let row = order.displayIndex(of: cell.rowID, in: rows),
                  let column = columns.displayPosition(of: cell.columnID) else { return nil }
            return GridCoord(row: row, displayColumn: column)
        }
        var resolvedRects: [GridRect] = []
        // Rows span every column the grid presents later too, a column added or shown included.
        if mode != .cells {
            if !columns.isEmpty {
                let all = 0...(columns.count - 1)
                for range in order.displayIndexes(of: rowIDs, in: rows).rangeView {
                    resolvedRects.append(GridRect(rows: range.lowerBound...(range.upperBound - 1), columns: all))
                }
            }
        } else {
            // Rows and columns that are no longer next to each other split the block, so no cell joins it.
            for rectangle in rectangles {
                let displayRows = order.displayIndexes(of: rectangle.rowIDs, in: rows)
                let displayColumns = IndexSet(rectangle.columnIDs.compactMap { columns.displayPosition(of: $0) })
                for rowRun in displayRows.rangeView {
                    for columnRun in displayColumns.rangeView {
                        resolvedRects.append(GridRect(
                            rows: rowRun.lowerBound...(rowRun.upperBound - 1),
                            columns: columnRun.lowerBound...(columnRun.upperBound - 1)
                        ))
                    }
                }
            }
        }
        let active = coord(activeCell)
            ?? resolvedRects.first.map { GridCoord(row: $0.rows.lowerBound, displayColumn: $0.columns.lowerBound) }
        return GridSelection(
            rectangles: resolvedRects,
            activeCell: active,
            anchor: coord(anchor) ?? active,
            columns: IndexSet(pickedColumnIDs.compactMap { columns.displayPosition(of: $0) }),
            mode: mode
        )
    }
}
