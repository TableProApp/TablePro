import Foundation

// GridSelection names display positions; this survives reloads, filters, reorders and remounts.
struct GridSelectionSnapshot: Equatable {
    struct Cell: Hashable {
        let rowID: RowID
        let columnID: DataGridColumnID
    }

    var rowRuns: RowIDRuns
    var rectangles: [Rectangle]
    var activeCell: Cell?
    var anchor: Cell?
    var pickedColumnIDs: [DataGridColumnID] = []
    var mode: GridSelection.Mode = .cells

    struct Rectangle: Hashable {
        let rowRuns: RowIDRuns
        let columnIDs: [DataGridColumnID]

        init(rowIDs: [RowID], columnIDs: [DataGridColumnID]) {
            self.init(rowRuns: RowIDRuns(rowIDs), columnIDs: columnIDs)
        }

        init(rowRuns: RowIDRuns, columnIDs: [DataGridColumnID]) {
            self.rowRuns = rowRuns
            self.columnIDs = columnIDs
        }

        var rowIDs: [RowID] { Array(rowRuns) }
    }

    static let empty = GridSelectionSnapshot(rowIDs: [], rectangles: [], activeCell: nil, anchor: nil)

    var rowIDs: [RowID] { Array(rowRuns) }

    var isEmpty: Bool { rowRuns.isEmpty && activeCell == nil }

    // Rows named without rectangles are whole rows.
    init(rowIDs: [RowID], rectangles: [Rectangle], activeCell: Cell?, anchor: Cell?) {
        self.rowRuns = RowIDRuns(rowIDs)
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
        let runs = order.rowIDRuns(atDisplayIndexes: selection.affectedRows, in: rows)
        self.rowRuns = runs
        let isOneRectangle = selection.rectangles.count == 1
        self.rectangles = selection.rectangles.map { rect in
            Rectangle(
                rowRuns: isOneRectangle
                    ? runs
                    : order.rowIDRuns(atDisplayIndexes: IndexSet(integersIn: rect.rows.lowerBound...rect.rows.upperBound), in: rows),
                columnIDs: rect.columns.compactMap { columns.column(at: $0)?.id }
            )
        }
        self.activeCell = cell(selection.activeCell)
        self.anchor = cell(selection.anchor)
        self.pickedColumnIDs = selection.columns.compactMap { columns.column(at: $0)?.id }
        self.mode = selection.mode
    }

    var namedRowIDs: Set<RowID> {
        var named = Set(rowRuns)
        for rectangle in rectangles { named.formUnion(rectangle.rowRuns) }
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
            rowIDs: rowRuns.compactMap(transform),
            rectangles: rectangles.compactMap { rectangle in
                let rows = rectangle.rowRuns.compactMap(transform)
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
                for range in order.displayIndexes(of: rowRuns, in: rows).rangeView {
                    resolvedRects.append(GridRect(rows: range.lowerBound...(range.upperBound - 1), columns: all))
                }
            }
        } else {
            // Rows and columns that are no longer next to each other split the block, so no cell joins it.
            for rectangle in rectangles {
                let displayRows = order.displayIndexes(of: rectangle.rowRuns, in: rows)
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
