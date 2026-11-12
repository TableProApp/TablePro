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

    /// For rows a new read gave other ids: each selected row keeps its place under its new id, and a
    /// row the map leaves out went with the read, so it leaves the selection.
    func remappingRows(_ rowMap: [RowID: RowID]) -> GridSelectionSnapshot {
        func cell(_ cell: Cell?) -> Cell? {
            guard let cell, let rowID = rowMap[cell.rowID] else { return nil }
            return Cell(rowID: rowID, columnID: cell.columnID)
        }
        var remapped = self
        remapped.rowIDs = rowIDs.compactMap { rowMap[$0] }
        remapped.rectangles = rectangles.compactMap { rectangle in
            let rowIDs = rectangle.rowIDs.compactMap { rowMap[$0] }
            return rowIDs.isEmpty ? nil : Rectangle(rowIDs: rowIDs, columnIDs: rectangle.columnIDs)
        }
        remapped.activeCell = cell(activeCell)
        remapped.anchor = cell(anchor)
        return remapped.rowIDs.isEmpty && remapped.rectangles.isEmpty ? .empty : remapped
    }

    var namedRowIDs: Set<RowID> {
        var named = Set(rowIDs)
        for rectangle in rectangles { named.formUnion(rectangle.rowIDs) }
        if let activeCell { named.insert(activeCell.rowID) }
        if let anchor { named.insert(anchor.rowID) }
        return named
    }

    // A row the transform cannot place leaves, and a cell on it goes with it; the mode and columns stay.
    func mappingRows(_ transform: (RowID) -> RowID?) -> GridSelectionSnapshot {
        func cell(_ cell: Cell?) -> Cell? {
            guard let cell, let rowID = transform(cell.rowID) else { return nil }
            return Cell(rowID: rowID, columnID: cell.columnID)
        }
        var mapped = GridSelectionSnapshot(
            rowIDs: rowIDs.compactMap(transform),
            rectangles: rectangles.compactMap { rectangle in
                let rows = rectangle.rowIDs.compactMap(transform)
                return rows.isEmpty ? nil : Rectangle(rowIDs: rows, columnIDs: rectangle.columnIDs)
            },
            activeCell: cell(activeCell),
            anchor: cell(anchor)
        )
        guard !mapped.isEmpty else { return .empty }
        mapped.pickedColumnIDs = pickedColumnIDs
        mapped.mode = mode
        return mapped
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
